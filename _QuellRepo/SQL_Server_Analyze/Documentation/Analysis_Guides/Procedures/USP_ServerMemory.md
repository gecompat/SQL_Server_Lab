# [monitor].[USP_ServerMemory]

**Bereich:** Server Health<br>
**Zweck:** Verknüpft OS-, SQL-Prozess-, Target-/Total-Memory- und Clerk-Evidenz.<br>
**Beobachtungsart:** Snapshot + kumulative Runtimezähler<br>
**Kostenklasse:** LOW–MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Hat SQL Server oder das Betriebssystem Memory Pressure, und welche Clerks/Komponenten verwenden Speicher?** Sie unterstützt die Entscheidung, ob eine Instanzressource oder Konfiguration als belastbare Spur zum Symptom passt und welche unabhängige OS-, Verlaufs- oder Workloadevidenz fehlt.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine vollständige OS-/Hypervisorursache und ohne Delta oder Verlauf keine belastbare Aussage über einen dauerhaften Engpass. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_ServerMemory]
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `summary`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Je Resultset beschreibt eine Zeile eine Memory-Zusammenfassung, Prozess-/OS-Signal oder einen Memory Clerk.

## So lesen

Berücksichtigen Sie OS Available Memory, SQL Process Memory, Target/Total Server Memory, Pressure-Signale und größte Clerks gemeinsam.

## Warum kann das problematisch sein?

OS- und SQL-Druck gleichzeitig kann Paging, Cacheverdrängung und Grantknappheit verursachen.

## Wann ist es kein Problem?

Total Server Memory nahe Target ist im Steady State normal: SQL Server soll zugewiesenen Speicher nutzen.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Total≈Target allein ist gesund. Total≈Target plus kaum OS-Reserve, Physical Memory Low und Grantwaits ist problematisch. Prüfen Sie Grants, Buffer Pool und max server memory.

**Ähnlich aussehender Gegenfall:** Total Server Memory nahe Target ist im Steady State normal: SQL Server soll zugewiesenen Speicher nutzen. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Server-DMVs können plattform-, editions- oder berechtigungsbedingt fehlen. NULL und PARTIAL sind dann Evidenzgrenzen, keine Nullmessung.

Für `USP_ServerMemory` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | LOW–MEDIUM |
| Standardpfad | Ein Instanzsnapshot aus je einer OS-/Prozess-/SQLOS-Summaryzeile, den Top 100 aggregierten Memory-Clerk-Typen und einer aggregierten Memory-Grant-Zeile. |
| Teuerster Pfad | `@MaxZeilen = 0` auf einer Instanz mit sehr vielen Clerktypen; alle Clerkzeilen werden gruppiert und ausgegeben. Die Grantquelle bleibt eine Aggregatzeile, nicht ein Detailinventar. |
| Haupttreiber | Zahl der Memory-Clerk-Zeilen und -Typen; OS-, Prozess-, SQLOS- und Grantzusammenfassung besitzen feste Granularität. Das Clerk-TOP greift erst nach der Typaggregation. |
| Skalierung | Dominant ist Gruppierung/Sortierung von `sys.dm_os_memory_clerks`; die anderen DMVs und zwei Konfigurationszeilen sind klein. Keine Datenbank-, Datei- oder Cross-Database-Schleife. |
| Ressourcen | Geringe bis mittlere CPU/SQLOS-DMV-Arbeit und Speicher für Clerkaggregation; kein Volume-, msdb-, Benutzerdaten- oder Textzugriff. |
| Begrenzungswirkung | `@MaxZeilen` wird als TOP erst nach Gruppierung der Clerkzeilen angewandt. Es begrenzt ausgegebene Clerktypen, nicht den Scan/Aggregationsaufwand; Summary und Grantaggregat bleiben unabhängig davon vollständig. |
| Locking und Nebenwirkungen | Read-only; kurze Metadatenzugriffe und nicht atomare Runtime-DMVs. Es wird weder CHECKDB noch Growth noch Konfigurationsänderung ausgeführt. |
| Schutzmechanismus | Kein Gate. Die drei Summaryquellen und das Grantaggregat haben feste Granularität; nur die Clerktypen sind variabel und werden standardmäßig auf 100 Ausgaberänge begrenzt. Dieses TOP ist kein Schutz vor der vorherigen Clerkaggregation. |
| Sicherer Einsatz | Defaultlimit 100. Ein unbegrenztes Clerkresultset nur bei konkreter Clerkfrage und nach Prüfung der vorhandenen Typanzahl anfordern. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Snapshot + kumulative Runtimezähler“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Hat SQL Server oder das Betriebssystem Memory Pressure, und welche Clerks/Komponenten verwenden Speicher?

### Technischer Hintergrund

SQL Server Memory Manager balanciert Buffer Pool, Plan Cache, Query Execution Memory und weitere Clerks unter Min/Max Server Memory. OS-/Process-DMVs zeigen physisches Memory, Commit/Pagefile und Process Working Set. Target versus Total Server Memory und Memory Notifications liefern Drucksignale.

### Datenkette

`sys.configurations`, `sys.dm_exec_query_memory_grants`, `sys.dm_os_memory_clerks`, `sys.dm_os_process_memory`, `sys.dm_os_sys_info`, `sys.dm_os_sys_memory`.

### Source Select

Die zusammenfassende Speicherzeile kombiniert drei Singleton-DMVs mit den zwei relevanten Serverkonfigurationen:

```sql
SELECT
      [sm].[total_physical_memory_kb]
    , [sm].[available_physical_memory_kb]
    , [pm].[physical_memory_in_use_kb]
    , [pm].[process_physical_memory_low]
    , [si].[committed_kb]
    , [si].[committed_target_kb]
    , MAX(CASE WHEN [c].[name] = N'max server memory (MB)'
               THEN [c].[value_in_use] END) AS [MaxServerMemoryMb]
FROM [sys].[dm_os_sys_memory] AS [sm] WITH (NOLOCK)
CROSS JOIN [sys].[dm_os_process_memory] AS [pm] WITH (NOLOCK)
CROSS JOIN [sys].[dm_os_sys_info] AS [si] WITH (NOLOCK)
CROSS JOIN [sys].[configurations] AS [c] WITH (NOLOCK)
WHERE [c].[name] IN (N'min server memory (MB)', N'max server memory (MB)')
GROUP BY
      [sm].[total_physical_memory_kb], [sm].[available_physical_memory_kb]
    , [pm].[physical_memory_in_use_kb], [pm].[process_physical_memory_low]
    , [si].[committed_kb], [si].[committed_target_kb];
```

**Wichtig für die Eigenlast:** Summary ist klein. `dm_os_memory_clerks` wird vollständig gelesen und sofort nach Typ aggregiert; `@MaxZeilen` begrenzt dort das Ranking, nicht den DMV-Scan. Vertiefen Sie Grantdetails nur bei passendem Symptom.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Zustand; Clerk-/Processwerte verändern sich, einzelne Counter seit Start.

### Bewertung und Gegenprobe

Berücksichtigen Sie OS Available/Commit, process physical/virtual low flags, Total/Target, Max Server Memory, locked pages, clerk distribution, pending grants und paging gemeinsam. Hoher SQL-Memoryverbrauch allein ist erwartbar.

### Typische Fehlinterpretation

`Available MBytes` oder PLE besitzen keine universellen Einzelgrenzen. Buffer Pool und Query Grants sind unterschiedliche Verbraucher; VM Ballooning kann außerhalb SQL-Sicht liegen.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: `USP_BufferPoolAnalysis`, Current Memory Grants, Performance Counters und OS/Hypervisor-Telemetrie.

## Primärquellen

- [sys.dm_os_process_memory](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-process-memory-transact-sql?view=sql-server-ver17)

[Technische Detailbeschreibung](../08_Server_Health.md#3-monitorusp_servermemory)
