# W2-001 – Klassifikation der Bestandsbeispiele

| Merkmal | Wert |
|---|---|
| Arbeitspaket | `W2-001` |
| Status | `VALIDATED` |
| Prüfdatum | 2026-07-25 |
| Referenzarchiv | `Presentations/old/Performance Grundlagen V-2024.zip` |
| Referenzarchiv SHA-256 | `78e3d1d708758d1115a066eca1df2c66d6f26ba57903b764c98e901506892041` |
| Bewertete Artefakte | 19 SQL-Dateien und 4 TXT-Diagnoseabfragen |

## 1. Bewertungsmaßstab

`REUSE` bezeichnet eine fachlich und technisch weitgehend übernehmbare Quelle, die nur in den aktuellen Demo-Vertrag eingebettet werden muss. `REFACTOR` erhält den Kerncode, korrigiert jedoch Struktur, Scope oder Objektplatzierung. `REBUILD` übernimmt ausschließlich Lernziel und Ursache-Wirkungs-Idee. `DIAGNOSTIC_ONLY` kennzeichnet read-only Diagnosequellen, die nicht als Workload-Demo behandelt werden. `REMOVE` bedeutet, dass das Artefakt nicht in den aktiven Demo-Bestand migriert wird.

Die Klassifikation ist eine Inhalts- und Migrationsentscheidung. Sie ist keine Runtime-Freigabe der historischen Skripte. Kein Skript des Referenzarchivs darf direkt gegen eine SQL-Server-Instanz ausgeführt werden.

## 2. Gesamtergebnis

| Entscheidung | Anzahl |
|---|---:|
| `REUSE` | 0 |
| `REFACTOR` | 1 |
| `REBUILD` | 14 |
| `DIAGNOSTIC_ONLY` | 4 |
| `REMOVE` | 4 |

Es existiert kein direkter `REUSE`-Kandidat. Jedes Bestandsbeispiel verletzt mindestens eine aktuelle Projektgrenze: fehlender Demo-Lifecycle, externe Datenbankabhängigkeit, nichtdeterministische Daten, globale Cache- oder Instanzeingriffe, fehlender Cleanup, nicht eingegrenzte Diagnoseausgabe oder fehlende Versions-/Berechtigungsbehandlung.

Die fachlichen Kerne bleiben überwiegend relevant. Vierzehn Beispiele werden neu aufgebaut, ein kompaktes APPLY-Beispiel wird refaktoriert, vier DMV-Abfragen werden ausschließlich als Diagnosequellen weitergeführt und vier unscharfe oder fachfremde Sammelskripte werden entfernt.

## 3. Klassifikationsmatrix

| Quelle | Kurzthema | Entscheidung | Ziel-Demo(s) | Migrationswelle | Sicherheitsrahmen |
|---|---|---|---|---|---|
| `SRC-LEGACY-008` / `tsql_isolation_demo.sql` | READ COMMITTED blocking, SNAPSHOT update conflict and SERIALIZABLE range locks | `REBUILD` | `CON-001`, `CON-002`, `CON-003` | `W2-A` | `YELLOW` |
| `SRC-LEGACY-009` / `Beispiele/Apply.sql` | CROSS/OUTER APPLY compared with joins and an inline TVF | `REFACTOR` | `QRY-009`, `QRY-010` | `W2-C` | `GREEN` |
| `SRC-LEGACY-010` / `Beispiele/BufferPool füllt sich.sql` | Cold and warm cache behavior in the buffer pool | `REBUILD` | `STL-006`, `DGN-001` | `W2-B` | `RED` |
| `SRC-LEGACY-011` / `Beispiele/DMV_Count_Rows_in_Table.txt` | Catalog-based row-count estimate for a heap or clustered table | `DIAGNOSTIC_ONLY` | `DGN-002`, `STL-004` | `W2-A` | `GREEN` |
| `SRC-LEGACY-012` / `Beispiele/DMV_MemoryGrant.txt` | Current query memory grants and associated request text | `DIAGNOSTIC_ONLY` | `DGN-002`, `OPT-014`, `RES-004` | `W2-A` | `GREEN` |
| `SRC-LEGACY-013` / `Beispiele/DMV_Requests_text.txt` | Current requests with resource counters, blocking and SQL text | `DIAGNOSTIC_ONLY` | `DGN-002` | `W2-A` | `GREEN` |
| `SRC-LEGACY-014` / `Beispiele/DMV_WaitStats.txt` | Top server-wide waits | `DIAGNOSTIC_ONLY` | `RES-007`, `DGN-002` | `W2-A` | `GREEN` |
| `SRC-LEGACY-015` / `Beispiele/for xml path.sql` | FOR XML PATH string concatenation recipe | `REMOVE` | `QRY-012` | `NONE` | `NOT_APPLICABLE` |
| `SRC-LEGACY-016` / `Beispiele/functions_1.sql` | General T-SQL function notebook | `REMOVE` | – | `NONE` | `NOT_APPLICABLE` |
| `SRC-LEGACY-017` / `Beispiele/Index_usage_partition.sql` | Partition-aware MAX query and partition elimination | `REBUILD` | `QRY-012` | `W2-B` | `GREEN` |
| `SRC-LEGACY-018` / `Beispiele/Join Typen.sql` | Nested Loops, Merge, Hash and bitmap filtering examples | `REBUILD` | `OPT-012` | `W2-A` | `GREEN` |
| `SRC-LEGACY-019` / `Beispiele/json_parallel.sql` | JSON scalar extraction and OPENJSON in a join | `REBUILD` | `QRY-012`, `RES-002` | `W2-C` | `YELLOW` |
| `SRC-LEGACY-020` / `Beispiele/NON-Sargable.sql` | Implicit conversion, functions on columns, optional predicates and non-searchable expressions | `REBUILD` | `QRY-001`, `QRY-002`, `QRY-003`, `QRY-004` | `W2-A` | `GREEN` |
| `SRC-LEGACY-021` / `Beispiele/Page Größe bzw. Max Spalten.sql` | Maximum result/table column counts and oversized rows | `REMOVE` | `STL-001` | `NONE` | `NOT_APPLICABLE` |
| `SRC-LEGACY-022` / `Beispiele/Parameter Sniffing.sql` | Skew-sensitive parameter compilation and plan reuse | `REBUILD` | `OPT-008`, `OPT-009` | `W2-A` | `YELLOW` |
| `SRC-LEGACY-023` / `Beispiele/Partition Elimination.sql` | Partition elimination and actual rows read | `REBUILD` | `QRY-012`, `RES-002` | `W2-B` | `GREEN` |
| `SRC-LEGACY-024` / `Beispiele/Partition Views.sql` | Partitioned tables and partitioned UNION ALL views | `REMOVE` | `QRY-012` | `NONE` | `NOT_APPLICABLE` |
| `SRC-LEGACY-025` / `Beispiele/perfSubsel.sql` | Correlated scalar subquery versus pre-aggregation and set-based rewrite | `REBUILD` | `QRY-005`, `QRY-010` | `W2-B` | `YELLOW` |
| `SRC-LEGACY-026` / `Beispiele/schnell ist nicht immer Ressourcen schonend.sql` | Elapsed time versus CPU/resource consumption and predicate placement | `REBUILD` | `RES-002`, `QRY-001` | `W2-B` | `YELLOW` |
| `SRC-LEGACY-027` / `Beispiele/SearchNull.sql` | NULL predicates, OR/IN combinations and index access | `REBUILD` | `QRY-006`, `IDX-003` | `W2-B` | `GREEN` |
| `SRC-LEGACY-028` / `Beispiele/Tipping Point AdventureWorks2022.sql` | Lookup-to-scan tipping point | `REBUILD` | `IDX-004` | `W2-A` | `GREEN` |
| `SRC-LEGACY-029` / `Beispiele/uniquifier.sql` | Uniquifier storage and increment behavior for nonunique clustered indexes | `REBUILD` | `IDX-002`, `STL-001` | `W2-C` | `YELLOW` |
| `SRC-LEGACY-030` / `Beispiele/Was_weiß_der_Optimizer_TagID.sql` | Optimizer knowledge from indexes, statistics and uniqueness constraints | `REBUILD` | `OPT-002`, `OPT-003`, `OPT-004` | `W2-B` | `YELLOW` |

## 4. Einzelbefunde

### SRC-LEGACY-008 – tsql_isolation_demo.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `CON-001`, `CON-002`, `CON-003`  
**Wert:** The scenario set covers three central isolation effects and can support the concurrency module.

**Befunde**

- No deterministic setup, barriers, timeout, recovery or cleanup are provided.
- The SNAPSHOT conflict sequence updates the row in both sessions before the intended conflict point and is not a reliable reproduction of error 3960.
- The database option change is only mentioned as a manual prerequisite and is not restored.

**Erforderliche Folgearbeit**

- Split the content into the canonical isolation demos and use FWK-006 for session order.
- Create a marker-protected synthetic database and restore database options in cleanup.
- Assert blocking relationships, error 3960 and range-lock behavior separately.

### SRC-LEGACY-009 – Beispiele/Apply.sql

**Entscheidung:** `REFACTOR`  
**Ziel:** `QRY-009`, `QRY-010`  
**Wert:** The compact temp-table examples clearly show row-preserving and row-eliminating APPLY semantics.

**Befunde**

- The script changes context to master and creates a user function there.
- One synthetic row contains an unapproved real first name.
- Semantic equivalence is shown, but no performance question, baseline or cleanup contract is defined.

**Erforderliche Folgearbeit**

- Move all objects into a marker-protected demo database and use neutral values.
- Separate APPLY semantics from inline-TVF optimization evidence.
- Add result-equivalence assertions and a measured comparison where performance is claimed.

### SRC-LEGACY-010 – Beispiele/BufferPool füllt sich.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `STL-006`, `DGN-001`  
**Wert:** The intended contrast between first and repeated reads is relevant to storage diagnostics.

**Befunde**

- The script depends on unavailable application tables.
- It instructs a SQL Server restart and executes DBCC FREEPROCCACHE and DBCC DROPCLEANBUFFERS.
- Only elapsed effects are implied; buffer residency, logical reads and physical reads are not captured through a controlled A/B contract.

**Erforderliche Folgearbeit**

- Rebuild with deterministic synthetic data and a dedicated isolated instance profile.
- Keep cache-clearing operations red and require explicit confirmation.
- Measure logical/physical reads and buffer residency without treating a single elapsed time as universal.

### SRC-LEGACY-011 – Beispiele/DMV_Count_Rows_in_Table.txt

**Entscheidung:** `DIAGNOSTIC_ONLY`  
**Ziel:** `DGN-002`, `STL-004`  
**Wert:** The join between sys.partitions, sys.objects and sys.schemas is a useful source query.

**Befunde**

- The result is metadata-based and must not be described as an exact COUNT_BIG result.
- Schema and object names are hard coded.
- NOLOCK hints are unnecessary for this catalog query and obscure the method.

**Erforderliche Folgearbeit**

- Publish as a parameterized diagnostic source query with scope and accuracy notes.
- Return heap/clustered row counts without double counting nonclustered indexes.
- Document permissions, partition scope and comparison with an exact count.

### SRC-LEGACY-012 – Beispiele/DMV_MemoryGrant.txt

**Entscheidung:** `DIAGNOSTIC_ONLY`  
**Ziel:** `DGN-002`, `OPT-014`, `RES-004`  
**Wert:** The query combines memory-grant, request, session, resource-governor and SQL-text evidence.

**Befunde**

- A hard-coded RAM percentage and the maximum-allocation formula are not portable; the conditional cap logic is not a safe general model.
- Login, program, context information and SQL text can contain sensitive data.
- Permissions and SQL Server 2022+ VIEW SERVER PERFORMANCE STATE requirements are not handled.
- Reading and sorting diagnostic DMVs can itself consume resources and must be bounded.

**Erforderliche Folgearbeit**

- Rebuild as a bounded diagnostic with explicit permissions, truncation and privacy controls.
- Report requested, required, granted, used and maximum-used memory directly before deriving ratios.
- Separate waiting grants from granted requests and avoid undocumented capacity formulas.

### SRC-LEGACY-013 – Beispiele/DMV_Requests_text.txt

**Entscheidung:** `DIAGNOSTIC_ONLY`  
**Ziel:** `DGN-002`  
**Wert:** The selected request columns form a useful introductory live-request query.

**Befunde**

- SQL text, database/user identifiers and plan handles require privacy and permission handling.
- The query has no user-process filter, scope limit, version handling or statement-offset extraction.
- Current waits and accumulated session state are not distinguished.

**Erforderliche Folgearbeit**

- Add version-aware permissions, filters, row limits and statement-level text extraction.
- Make SQL text optional and clearly mark sensitive columns.
- Link follow-up paths for blocking, waits, plans and memory grants.

### SRC-LEGACY-014 – Beispiele/DMV_WaitStats.txt

**Entscheidung:** `DIAGNOSTIC_ONLY`  
**Ziel:** `RES-007`, `DGN-002`  
**Wert:** The query introduces resource and signal wait components.

**Befunde**

- sys.dm_os_wait_stats is cumulative since startup or reset; the script presents absolute totals without a delta window.
- The static exclusion list is incomplete and version-dependent.
- The query does not separate server-wide waits from request/session/task waits.

**Erforderliche Folgearbeit**

- Use captured deltas and record the measurement interval and server start time.
- Replace the embedded ignore list with documented metadata or an explicit teaching subset.
- Cross-reference session/request wait evidence and avoid clearing server-wide counters.

### SRC-LEGACY-015 – Beispiele/for xml path.sql

**Entscheidung:** `REMOVE`  
**Ziel:** `QRY-012`  
**Wert:** The file demonstrates XML escaping and TYPE/value extraction, but primarily as a syntax notebook.

**Befunde**

- It depends on a public sample database and generates DROP TABLE commands as text.
- It has no controlled performance hypothesis or A/B evidence.
- Modern string aggregation and XML-cost teaching require a different, measured design.

**Erforderliche Folgearbeit**

- Do not migrate the file.
- Re-author any required XML/string cost comparison inside QRY-012 with synthetic data.

### SRC-LEGACY-016 – Beispiele/functions_1.sql

**Entscheidung:** `REMOVE`  
**Ziel:** keine aktive Ziel-Demo  
**Wert:** Individual snippets may be useful as language reference material.

**Befunde**

- The file mixes unrelated functions, version-specific syntax, dates, partition functions and external sample databases.
- It has no single performance learning objective or reproducible baseline.
- Several examples rely on existing objects and database context.

**Erforderliche Folgearbeit**

- Do not migrate the notebook as a performance demo.
- Recreate only the specific function needed by a future demo within that demo's setup.

### SRC-LEGACY-017 – Beispiele/Index_usage_partition.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `QRY-012`  
**Wert:** The file raises a valid issue: a global aggregate on a partitioned index can require work across partitions.

**Befunde**

- It depends on a separately created database, table and partition function.
- It uses object_id() and NOLOCK and hard-codes the partition-function name.
- The workaround is presented without result-equivalence, plan or read assertions.

**Erforderliche Folgearbeit**

- Rebuild with deterministic partitioned data and catalog-based object resolution.
- Compare global aggregate, partition-aware alternative and direct partition elimination.
- Measure reads and plan shape without NOLOCK.

### SRC-LEGACY-018 – Beispiele/Join Typen.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `OPT-012`  
**Wert:** The four operator families align with the optimizer module.

**Befunde**

- The queries depend on two public sample databases and assume specific plans from a particular data distribution and build.
- SELECT * and DISTINCT change row width and costing without a controlled model.
- The comments treat expected operator selection as fixed rather than cost- and version-dependent.

**Erforderliche Folgearbeit**

- Rebuild with synthetic inputs that independently vary cardinality, ordering and width.
- Assert eligible plan alternatives and actual row counts rather than a single mandatory icon.
- Separate bitmap filtering from the basic three-join comparison.

### SRC-LEGACY-019 – Beispiele/json_parallel.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `QRY-012`, `RES-002`  
**Wert:** The contrast between relational parameters, JSON_VALUE and a JSON rowset can support measurable JSON-cost teaching.

**Befunde**

- The script depends on an internal database model and random JSON membership.
- No statistics, plan, result-equivalence or parallelism evidence is captured.
- The OPENJSON join compares account-number and account-id concepts ambiguously.

**Erforderliche Folgearbeit**

- Rebuild with deterministic JSON and relational inputs in a synthetic database.
- Validate identical result sets and measure parse, join, read and CPU effects.
- Treat parallelism as an observed plan property, not as an assumption from the filename.

### SRC-LEGACY-020 – Beispiele/NON-Sargable.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `QRY-001`, `QRY-002`, `QRY-003`, `QRY-004`  
**Wert:** The file contains several high-value query-pattern teaching cases.

**Befunde**

- It modifies indexes in a public sample database and embeds fixed read counts.
- The end-of-year BETWEEN boundary is not safe for all temporal precisions; the replacement must use a half-open interval.
- Four distinct learning objectives are mixed in one script.
- Optional-parameter behavior is not version-aware for PSP/OPPO.

**Erforderliche Folgearbeit**

- Split the file across QRY-001, QRY-002, QRY-003 and QRY-004.
- Use deterministic synthetic data and result-equivalence assertions.
- Keep the already validated QRY-001 implementation as the canonical SARGability path.

### SRC-LEGACY-021 – Beispiele/Page Größe bzw. Max Spalten.sql

**Entscheidung:** `REMOVE`  
**Ziel:** `STL-001`  
**Wert:** The script records engine-limit experiments related to row and result width.

**Befunde**

- The 149 KB manually enumerated statement is not maintainable or didactically proportional.
- Most sections test parser/result-set limits rather than SQL Server performance.
- Cursor and 4096-column fragments do not provide a controlled storage or I/O experiment.

**Erforderliche Folgearbeit**

- Do not migrate the file.
- Cover row width and pages through the smaller STL-001 design; cite engine limits in documentation only when needed.

### SRC-LEGACY-022 – Beispiele/Parameter Sniffing.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `OPT-008`, `OPT-009`  
**Wert:** The increasing department distribution is suitable for demonstrating parameter-sensitive plan reuse.

**Befunde**

- The script creates and drops a fixed database, uses non-deterministic data, system-catalog row sources, high MAXDOP and DBCC FREEPROCCACHE.
- It changes database-scoped PARAMETER_SNIFFING configuration and does not provide a contract-based restore path.
- It is not separated into classic behavior and SQL Server 2022 PSP behavior.

**Erforderliche Folgearbeit**

- Rebuild deterministic skew with FWK-003 and marker-protected lifecycle.
- Compare classic single-plan behavior with PSP eligibility and controlled skips.
- Use query-local or database-local evidence and avoid clearing the instance plan cache.

### SRC-LEGACY-023 – Beispiele/Partition Elimination.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `QRY-012`, `RES-002`  
**Wert:** The known-versus-unknown partition predicate is a useful plan-reading exercise.

**Befunde**

- Setup is partly commented and the script depends on a fixed database state.
- Random generation and system-catalog row sources make the distribution unstable.
- Comments risk implying a one-to-one relationship between partitions and workers, which is not a SQL Server guarantee.

**Erforderliche Folgearbeit**

- Rebuild deterministic partitions and compare known, unknown and range predicates.
- Assert partitions accessed and actual rows read.
- Keep worker/task interpretation separate from physical partition count.

### SRC-LEGACY-024 – Beispiele/Partition Views.sql

**Entscheidung:** `REMOVE`  
**Ziel:** `QRY-012`  
**Wert:** Some fragments demonstrate trusted CHECK constraints and branch elimination.

**Befunde**

- The script mixes two separate partitioning models and a copied supplier example.
- It creates many permanent objects, contains manual session-kill notes and has no complete cleanup.
- Partitioned views are not a current canonical demo bundle and would dilute QRY-012.

**Erforderliche Folgearbeit**

- Do not migrate the file as a standalone demo.
- Retain only the trusted-constraint concept when designing QRY-012 or OPT-004.

### SRC-LEGACY-025 – Beispiele/perfSubsel.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `QRY-005`, `QRY-010`  
**Wert:** The file contains a strong example of repeated work caused by correlation and conditional aggregation.

**Befunde**

- It assumes a pre-existing database and potentially ten million non-deterministic rows.
- It uses version-specific GENERATE_SERIES, fixed historical timings and optional compatibility-level changes.
- The comparison creates large temp results and lacks a bounded cleanup/result contract.

**Erforderliche Folgearbeit**

- Rebuild with scalable deterministic profiles and a smaller default dataset.
- Compare correlated, UNION ALL and pre-aggregated forms with identical checksums.
- Express performance expectations as relative reads/CPU and separate compatibility-level variants.

### SRC-LEGACY-026 – Beispiele/schnell ist nicht immer Ressourcen schonend.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `RES-002`, `QRY-001`  
**Wert:** The central message that lower latency can consume more total CPU is important.

**Befunde**

- The script depends on an internal data model and hard-codes MAXDOP 64 and historical measurements.
- Forced LOOP joins and complex expressions mix parallelism, join choice and SARGability.
- No host capability or concurrency impact is measured.

**Erforderliche Folgearbeit**

- Split parallel-efficiency evidence from predicate-rewrite evidence.
- Use a bounded DOP derived from the test profile and compare elapsed time, CPU, reads and worker distribution.
- Run only in an isolated yellow profile.

### SRC-LEGACY-027 – Beispiele/SearchNull.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `QRY-006`, `IDX-003`  
**Wert:** The file illustrates that NULL values can participate in nonclustered index access.

**Befunde**

- It creates a fixed database and uses non-deterministic data plus a million-row filler value.
- The comment 'index is used' is workload-specific and not a general guarantee.
- NULL semantics and physical access are mixed without result and plan contracts.

**Erforderliche Folgearbeit**

- Rebuild deterministic NULL and non-NULL distributions.
- Separate logical NULL semantics from index-access evidence.
- Compare IS NULL, IN, OR and anti-semi patterns with controlled plans and reads.

### SRC-LEGACY-028 – Beispiele/Tipping Point AdventureWorks2022.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `IDX-004`  
**Wert:** The two close row counts provide an intuitive starting point for cost-based access changes.

**Befunde**

- The script depends entirely on one public sample database and its current statistics.
- Specific row counts and operator choices are build-, statistics- and index-dependent.
- No synthetic setup, mitigation, comparison or cleanup exists.

**Erforderliche Folgearbeit**

- Rebuild with a synthetic wide table and adjustable selectivity.
- Observe the lookup/scan transition as a range, not a universal threshold.
- Measure rows, pages and estimated cost under the same data profile.

### SRC-LEGACY-029 – Beispiele/uniquifier.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `IDX-002`, `STL-001`  
**Wert:** The temp-table comparison and page evidence address a valuable SQL Server storage internal.

**Befunde**

- The script starts in an internal database and uses system catalogs as row generators.
- It relies on undocumented DBCC PAGE-style output and repeated tempdb page inspection.
- The prepared overflow path targets billions of duplicates and is unsafe for a standard lab.

**Erforderliche Folgearbeit**

- Rebuild the normal uniquifier comparison with bounded synthetic rows.
- Isolate undocumented page inspection as an optional advanced evidence path with explicit caveats.
- Remove the overflow workload or replace it with a documented conceptual explanation.

### SRC-LEGACY-030 – Beispiele/Was_weiß_der_Optimizer_TagID.sql

**Entscheidung:** `REBUILD`  
**Ziel:** `OPT-002`, `OPT-003`, `OPT-004`  
**Wert:** The script distinguishes access paths from cardinality knowledge and shows how trusted keys add logical information.

**Befunde**

- It disables automatic statistics, clears the global plan cache repeatedly and generates several million non-deterministic rows.
- Multiple statistics, index-order and constraint questions are combined into one long scenario.
- Fixed estimates and SAMPLE 0 ROWS behavior are not framed as version/build-dependent evidence.

**Erforderliche Folgearbeit**

- Split statistics anatomy, sampling and schema-knowledge cases across OPT-002/003/004.
- Use deterministic bounded profiles and query-specific recompilation rather than global cache clearing.
- Restore all database options through the framework lifecycle.

## 5. Verbindliche Migrationsreihenfolge

### W2-A – zuerst

Diese Gruppe enthält die fachlich zentralen Beispiele und Diagnosequellen, die unmittelbar in vorhandene Curriculum-Bündel überführt werden können: `SRC-LEGACY-008`, `011` bis `014`, `018`, `020`, `022` und `028`. Der bereits validierte Pilot `QRY-001` bleibt kanonisch; die Altquelle `SRC-LEGACY-020` liefert keine konkurrierende Implementierung.

### W2-B – danach

Diese Gruppe benötigt größere synthetische Datenmodelle oder eine Aufteilung in mehrere Evidenzpfade: `SRC-LEGACY-010`, `017`, `023`, `025`, `026`, `027` und `030`.

### W2-C – Vertiefung

Diese Gruppe besitzt höheren Internals- oder Umstrukturierungsaufwand: `SRC-LEGACY-009`, `019` und `029`. Die Undocumented-Page-Evidenz des Uniquifier-Themas bleibt optional und wird nicht Voraussetzung für den Kernpfad.

### Keine Migration

`SRC-LEGACY-015`, `016`, `021` und `024` werden nicht in aktive Demo-Pfade übernommen. Einzelne fachliche Aspekte dürfen in einer neuen Demo neu formuliert werden; die historischen Dateien bleiben ausschließlich Quellen.

## 6. Auswirkungen auf W2-002 bis W2-006

`W2-002` entfernt die in dieser Klassifikation benannten festen Datenbank-, Objekt- und Umgebungsabhängigkeiten. `W2-003` baut REFACTOR- und REBUILD-Kandidaten nach dem vollständigen Demo-Vertrag neu auf. `W2-004` übernimmt ausschließlich die vier `DIAGNOSTIC_ONLY`-Quellen und ergänzt Version, Rechte, Scope, Delta-Methodik, Privacy und Kosten. `W2-005` misst die Kernaussagen erneut. `W2-006` verwendet die hier festgelegten kanonischen Demo-IDs.

## 7. Validierung

Der maschinenlesbare Vertrag steht in [`legacy_example_classification.json`](legacy_example_classification.json). Der Validator prüft die 23 IDs, Entscheidungssummen, Ziel-IDs, Archivpfade und SHA-256-Werte direkt gegen das unveränderte verschachtelte Referenzarchiv. Er stellt außerdem sicher, dass keine historische Datei als direkt ausführbar freigegeben wird.
