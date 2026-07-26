Ja. Der aktuelle `main`-Stand ist organisatorisch sauber, enthält aber weiterhin mehrere geplante Themenblöcke.



| Priorität         | Themenblock                                             | Status|
| ---- | ----- | --- |
| Nächste Umsetzung | \*\*RUNTIME-001 – External Runtime und SQL CLR\*\*          | Vollständig geplant, aber noch nicht implementiert. Vorgesehen sind `USP\_ExternalRuntimeAnalysis` und `USP\_ClrAnalysis` (\[Plan](https://github.com/gecompat/SQL\_Server\_Analyze/blob/main/Documentation/Architecture/External\_Runtime\_CLR\_Analysis\_Plan.md)). |
| P1                | \*\*DIAG-003 – Parameter-Evidenz\*\*                        | Compile-Parameter, verfügbare Runtimeparameter, Provenienz und eindeutige Status für nicht erfassbare Werte fehlen noch.  |
| P2                | \*\*DIAG-004/005 – Request-, Plan- und Optimizerkontext\*\* | Konsolidierter Requestkontext ohne erneute DMV-Lesung sowie zusätzliche Planwarnungen, Runtime Feedback, PSP-/OPPO- und Query-Store-Kontexte fehlen noch.|
| P2                | \*\*SQL-Server-2025-Vertiefung\*\*                          | Vector-Index-Laufzeit, JSON-Index-Inventar, TempDB Resource Governance, Statistics auf Readable Secondaries und replica-aware Query Store.|
| P2                | \*\*Zusätzliche Betriebsdiagnosen\*\*                       | Linked Server (`OPS-005`), Datenbankportabilität (`OPS-006`) und `msdb`-Gesundheit/Retention (`OPS-008`). |
| P3                | \*\*Kleinere Betriebsdiagnosen\*\*                          | Cursoranalyse (`OPS-007`) und Benutzerobjekte in Systemdatenbanken (`OPS-009`). |
| Architektur       | \*\*COLL-001 – Collation-Portabilität\*\*                   | Das Framework ist weiterhin nur innerhalb der dokumentierten Collationgrenze freigegeben. Gemischte Server-, `tempdb`-, Framework- und Zieldatenbank-Collations sind noch nicht gehärtet und getestet.|
| Persistenz        | \*\*SC-023 – Snapshot/Baseline-Ausbau\*\*                   | Der erste Performance-Counter-Slice ist implementiert. Wait-, I/O-, Datenbank-, Query- und Plan-Collector, Rollups sowie getrennte Scheduler-/Exportpakete fehlen noch.|
| Extern            | \*\*SC-024 – Fleet Correlation\*\*                          | Design vorhanden; benötigt eine externe zentrale Komponente und eine Isolation-/Transportentscheidung.|
| Extern            | \*\*SC-025 – Restore- und Host-Nachweis\*\*                 | Runbook vorhanden; tatsächliche Ausführung benötigt eine autorisierte isolierte Zielumgebung.|
| Nachweise         | \*\*Erweiterte Plattform- und Lasttests\*\*                 | Feature-positive Windows- und Azure-MI-Tests, gemischte Collations, kontrollierte Last-, Soak-, Failover- sowie externe Restore-/Storage-Nachweise fehlen weiterhin (\[Testgrenzen](https://github.com/gecompat/SQL\_Server\_Analyze/blob/main/Documentation/Quality/Test\_Matrix.md)). |

Der maschinenlesbare Future-Backlog enthält derzeit \*\*13 nicht implementierte Einträge\*\*: einen P1-, zehn P2- und zwei P3-Einträge (\[Future Enhancement Backlog](https://github.com/gecompat/SQL\_Server\_Analyze/blob/main/Metadata/Quality/Future\_Enhancement\_Backlog.csv)).

Wichtig: Es gibt aktuell \*\*keine offenen Issues, Pull Requests oder Arbeitsbranches\*\*; ausschließlich `main` ist vorhanden. Die bestehende Special-Case-Testmatrix ist abgeschlossen. Die oben genannten Punkte sind ausdrücklich zukünftige Erweiterungen beziehungsweise zusätzliche Evidence-Klassen, keine unerledigten Arbeiten aus einem offenen PR.

Meine Hauptempfehlung ist, als Nächstes \*\*RUNTIME-001\*\* umzusetzen, weil es im Repository ausdrücklich als nächstes SubProject festgelegt ist. Danach bietet sich `DIAG-003` als fachlich engere Erweiterung der bereits bestehenden Request- und Plananalyse an. Aktueller `main`: \[Commit `424d9281`](https://github.com/gecompat/SQL\_Server\_Analyze/commit/424d928121cd4086a67f358e5d388b92d2a74e55).





---

Der belastbare Gesamtplan steht. Grundlage ist der aktuelle `main`-Stand [`be5e05b`](https://github.com/gecompat/SQL_Server_Analyze/commit/be5e05b1dd942848d636d39fa107d7469f7cd755).

Wichtig ist eine fachliche Trennung:

| Bereich                     | Tatsächliche Einstufung                                                                         |
| --------------------------- | ----------------------------------------------------------------------------------------------- |
| `DIAG-003` bis `DIAG-005`   | Funktionale Bausteine vorhanden, Gesamtverträge fehlen – echte Abschlussarbeit                  |
| `RUNTIME-001`               | Current-State-Funktionalität implementiert; externe Laufzeitnachweise fehlen                    |
| `SC-023`                    | Erster Performance-Counter-Slice abgeschlossen; Ausbau um Collector und Rollups offen           |
| `SQL25-001` bis `SQL25-005` | `RESEARCHED_NOT_IMPLEMENTED` – Neuentwicklung                                                   |
| `OPS-005` bis `OPS-009`     | `RESEARCHED_NOT_IMPLEMENTED` – Neuentwicklung                                                   |
| Special Features            | Inventory ist implementiert; nicht jedes Feature benötigt automatisch eine eigene Deep Analysis |

Quelle: [Future Enhancement Backlog (gecompat, 2026)](https://github.com/gecompat/SQL_Server_Analyze/blob/main/Metadata/Quality/Future_Enhancement_Backlog.csv).

## Empfohlene Umsetzungsreihenfolge

### Welle 0 – Status- und Vertragsbereinigung

Vor funktionalen Änderungen:

* einheitliche Statuswerte festlegen:

  * `IMPLEMENTED_ACTIONS_GATE`
  * `IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING`
  * `PARTIAL_PRODUCT_FUNCTION`
  * `RESEARCHED_NOT_IMPLEMENTED`
  * `OPTIONAL_FUTURE`
* `RUNTIME-001` und den SC-023-Ausbau entsprechend eindeutig ausweisen;
* öffentlichen Resultsetvertrag für `DIAG-003` bis `DIAG-005` festschreiben;
* veralteten Status in `USP_SpecialFeatureInventory` korrigieren: `ENCRYPTION` verweist bereits auf `USP_EncryptionAnalysis`, wird aber noch als `PLANNED` ausgegeben;
* optionale Erweiterungen wie Runtime-Snapshot-Collector oder eigener RUNTIME-Teilinstaller nicht mehr als fehlende Kernfunktion behandeln.

### Welle 1 – Gemeinsame laufinterne Evidenzbasis

Für `DIAG-003` bis `DIAG-005` wird zuerst ein interner Snapshot-Owner geschaffen.

Dieser materialisiert nur die tatsächlich angeforderten Quellen:

* `sys.dm_exec_requests`;
* `sys.dm_exec_sessions`;
* `sys.dm_exec_connections`;
* `sys.dm_os_waiting_tasks`;
* Memory Grants, Tasks, Scheduler und Transaktionen nur bei aktivem Consumer;
* SQL-Text, Input Buffer und Pläne erst nach Kandidatenauswahl und Begrenzung.

`USP_CurrentOverview` und seine Child-Procedures verwenden anschließend denselben Snapshot. Der vorhandene Mechanismus `@ParentQueryStatsSnapshot` aus der Plan-Cache-Analyse dient als Architekturvorbild.

Verbindlich:

* keine große „alles lesen“-Momentaufnahme;
* jeder aktivierte Systembestand höchstens einmal je Aufruf;
* `CapturedAtUtc` je Quelle;
* Requestende, Cache-Eviction und Berechtigungsfehler als Status statt scheinbar vollständiger Daten;
* Einzelaufrufe lesen weiterhin frisch und können niemals alte Parent-Daten verwenden.

### Welle 2 – `DIAG-003` Parameter-Evidenz abschließen

Das bestehende `parametersAndVariants` wird zu einem stabilen Parametervertrag ausgebaut – bevorzugt als kanonisches Resultset `parameters`.

Mindestens erforderlich:

* Candidate-, Session-, Request-, Statement-, Query- und Planbezug;
* Parametername und Datentyp;
* Compile- und Runtimewert getrennt;
* getrennte Kennzeichen, ob das jeweilige XML-Attribut überhaupt vorhanden war;
* `ValueSource`, `SourceObservedAtUtc` und – sofern tatsächlich bekannt – `ValueCapturedAtUtc`;
* `IsCurrentExecution`, `IsLastKnownExecution`, `IsComplete`;
* differenzierte Statuswerte wie `AVAILABLE`, `SQL_NULL`, `NOT_COLLECTED`, `PLAN_EVICTED`, `REQUEST_FINISHED` und `LOCAL_VARIABLE_NOT_EXPOSED`.

Wesentliche Regeln:

* Ein fehlendes Runtimeattribut darf nicht mit SQL-`NULL` verwechselt werden.
* Die tatsächliche SQL-NULL-Repräsentation wird durch synthetische Engine-Tests ermittelt und nicht geraten.
* Input-Buffer-Text bleibt eine Textquelle; keine heuristisch behauptete vollständige Parameterextraktion.
* Compile-, Live- und Last-Actual-Plan behalten ihre unterschiedliche Zeitsemantik.
* Extended Events werden nur gelesen oder importiert; keine Session wird automatisch erstellt.
* Zusätzliche Planreads bleiben opt-in und gegebenenfalls High-Impact-gesteuert.
* Datenschutzmodi bleiben explizit; Repositorytests verwenden ausschließlich synthetische Werte.

Grundlage: [Diagnostic Information Enrichment Backlog (gecompat, 2026)](https://github.com/gecompat/SQL_Server_Analyze/blob/main/AI_Metadata/Internal_Documentation/Architecture/Diagnostic_Information_Enrichment_Backlog.md).

### Welle 3 – `DIAG-004` Statement-/Requestkontext

`USP_CurrentRequests`, `USP_CurrentSessions` und `USP_CurrentOverview` werden auf den gemeinsamen Snapshot umgestellt.

Ergänzt beziehungsweise vereinheitlicht werden:

* Statement, Batch und Input Buffer als getrennte Resultsets;
* Connection-, Task-, Scheduler-, Transaction-, Wait- und Memory-Grant-Kontext;
* Source- und Capture-Zeitpunkte;
* vollständige Trunkierungsinformationen;
* Request-/Statement-Handles und Offsetgültigkeit;
* SourceStatus je Teilquelle;
* gezielte Objektauflösung über direkte Katalogabfragen mit `LOCK_TIMEOUT 0`.

Tasks und Scheduler werden nur für bereits ausgewählte Requests gelesen. Identitätsfelder wie Login, Host und Clientprogramm bleiben auf fachlich begründete Detail- beziehungsweise RAW-Pfade beschränkt.

### Welle 4 – `DIAG-005` Plan-/Optimizerkontext

Die bestehende `USP_ExecutionPlanAnalysis` wird erweitert, nicht durch eine zweite konkurrierende Plananalyse ersetzt.

Neue normalisierte Gruppen:

* `planWarnings`;
* `optimizerContext`;
* `runtimeFeedback`;
* `queryStoreContext`;
* `feedbackAndVariants`.

Zu ergänzen sind insbesondere:

* Planwarnungen und ihre genaue XML-Provenienz;
* residuale Prädikate, Row Goals und Non-Parallel-Gründe;
* Memory Grant-, Spill- und Runtime-Counter-Kontext;
* Planattribute;
* Query-Store-Plan-, Force-, Hint- und Planwechselbezug;
* PSP-, OPPO- und Feedbackvarianten;
* Compile-/Runtimeparametervergleich als Indikator, nicht als Ursachenbeweis.

Pläne werden je Kandidat nur einmal beschafft und einmal zerlegt. Query Store wird anhand bereits ermittelter IDs oder Hashes gezielt gelesen, nicht breit gescannt.

### Unabhängiger Evidenztrack – `RUNTIME-001`

Hier soll zunächst kein weiterer Produktcode entstehen. Zuerst fehlen belastbare externe Nachweise:

* R, Python, Java, C# und Custom Language Extensions jeweils nur auf unterstützten Plattformen;
* Feature deaktiviert, Runtime fehlt, Launchpad fehlt, inaktiv und aktiv;
* SQL CLR mit zur Laufzeit kompiliertem synthetischem `SAFE`-Assembly-Test;
* getrennte Windows-/Linux-Grenzen;
* Sampling mit gültigem Delta sowie Resetgrenze;
* eingeschränkte Berechtigungen;
* `EXTERNAL_ACCESS`/`UNSAFE` nur in isolierten autorisierten Tests.

Kompilierte Assemblies, Laufzeitlogs und reale Umgebungsdaten werden nicht ins Repository übernommen. Gespeichert werden nur synthetische Testquellen und abstrakte Evidence-Gates.

Runtime-Snapshot-Collector und Teilinstaller sind separate optionale Entscheidungen und blockieren den Current-State-Abschluss nicht. Grundlage: [External Runtime/CLR Plan (gecompat, 2026)](https://github.com/gecompat/SQL_Server_Analyze/blob/main/Documentation/Architecture/External_Runtime_CLR_Analysis_Plan.md).

### Welle 5 – SC-023 ausbauen

Zuerst wird der derzeit auf `PERFORMANCE_COUNTERS` fest verdrahtete Collectorvertrag generalisiert:

* versioniertes Collector-Register statt festem CHECK-Constraint;
* idempotenter Upgradepfad bestehender Snapshotziele;
* collectorspezifische Metric- und Privacy-Klassifikation;
* Rollup-Tabelle mit zulässiger Aggregationsart je Metrik;
* Baselineanalyse nur innerhalb kompatibler Einheit, Scope- und Resetepoche.

Empfohlene Collector-Reihenfolge:

1. Wait-Stats-Deltas;
2. File-I/O-Deltas;
3. Memory-/Scheduler-Druck;
4. Datenbankkapazität;
5. External-Runtime- und CLR-Metriken nach abgeschlossenem RUNTIME-Evidenztrack.

Querytexte, Pläne und sensitive Payloads bleiben zunächst ausgeschlossen. Scheduler werden weiterhin nicht automatisch erzeugt. Siehe [Snapshot-/Baseline-Vertrag (gecompat, 2026)](https://github.com/gecompat/SQL_Server_Analyze/blob/main/Documentation/Architecture/Snapshot_Baseline_Package_Contract.md).

### Welle 6 – echte Neuentwicklung

SQL Server 2025:

1. `SQL25-002` JSON-Index-Inventar;
2. `SQL25-004` replica-aware Statistics;
3. `SQL25-003` TempDB Resource Governance;
4. `SQL25-005` Secondary Query Store;
5. `SQL25-001` Vector-Index-Runtimeanalyse.

Die aktuellen Kataloge sind dokumentiert, müssen aber weiterhin versionsadaptiv und per Dynamic SQL geschützt werden: [sys.json_indexes](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-json-indexes-transact-sql?view=sql-server-ver17), [sys.vector_indexes](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-vector-indexes-transact-sql?view=sql-server-ver17), [sys.stats](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-stats-transact-sql?view=sql-server-ver17).

Operational Diagnostics:

1. `OPS-006` Database Portability;
2. `OPS-008` `msdb` Health;
3. `OPS-009` Benutzerobjekte in Systemdatenbanken;
4. `OPS-007` begrenzte Cursoranalyse;
5. `OPS-005` Linked-Server-Inventar.

Der Linked-Server-Verbindungstest bleibt getrennt: `sp_testlinkedserver` besitzt keinen eigenen Per-Call-Timeoutparameter; relevante Timeouts sind Umgebungs- beziehungsweise Serverkonfiguration. Daher darf der Frameworkkern keinen garantiert begrenzten Test versprechen oder Timeoutkonfigurationen verändern. ([Microsoft, 2026a](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-testlinkedserver-transact-sql?view=sql-server-ver17); [Microsoft, 2026b](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-the-remote-query-timeout-server-configuration-option?view=sql-server-ver17)).

## Teststrategie

* Während der Entwicklung: nur betroffene statische Tests und SQL Server 2025.
* Am Ende jeder Welle: relevante Runtimeverträge auf 2019, 2022 und 2025.
* Am Gesamtabschluss: vollständiges Release Gate auf allen drei Versionen.
* RUNTIME-001 zusätzlich auf feature-positiven externen Zielen.
* Jeder Test verwendet synthetische Namen, Daten, Pläne und Payloads.
* Ein Status wird erst auf `IMPLEMENTED_ACTIONS_GATE` gesetzt, wenn Code, Installer, Inventare, Dokumentation und Runtimeevidenz übereinstimmen.

Meine Hauptempfehlung ist damit: **Welle 0 und 1, danach DIAG-003, DIAG-004 und DIAG-005 vollständig abschließen. RUNTIME-001 läuft als separater Evidence-Track. Anschließend folgt SC-023; SQL25 und OPS sind danach klar abgegrenzte Neuentwicklung.**

In diesem Planungsschritt wurden noch keine Repositorydateien geändert.

---

wurden in dieser Liste jetzt zusätzlich auch alle Backlog ToDos berücksichtigt?

---


Nein. Die Liste war primär ein Abschlussplan für **teilimplementierte Funktionen**. Zusätzlich aufgenommen wurden zwar einige neue Backlog-Themen (`SQL25-001` bis `SQL25-005` und `OPS-005` bis `OPS-009`), aber **nicht sämtliche Repository-Backlog-Todos**.

Beispielsweise wurden `SC-024`, `SC-025`, `COLL-001` sowie weitere Dokumentations-, Test-, Qualitäts- und technische Schulden nicht als Umsetzungswellen eingeplant.

Korrekte Einordnung: **Teilimplementierungen vollständig berücksichtigt; Gesamtbacklog nur teilweise berücksichtigt.** Für einen vollständigen Gesamtplan müssten alle Backlog- und Statusdateien konsolidiert, dedupliziert und priorisiert werden.




