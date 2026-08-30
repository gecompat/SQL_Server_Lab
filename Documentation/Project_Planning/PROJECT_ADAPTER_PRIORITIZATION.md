# Project-Adapter-Priorisierung

| Merkmal | Wert |
|---|---|
| Status | `PLANNING_DECISION` |
| Stand | 2026-08-30 |
| Bezieht sich auf | `MASTER_IMPLEMENTATION_PLAN.md` Wellen 4, 6, 7 und 7a |
| Runtime-Nachweis | Partner-PR und lokaler SQL-2025-Lifecycle; verbleibende Grenzen in `Documentation/Quality/KNOWN_LIMITATIONS.md` |

## 1. Entscheidung

Nach Abschluss der Sample-Welle 3 und der nativen Hyper-V-Lifecycle-Grundlage
werden die drei **Project Adapter** als nächste Partnerintegrationen umgesetzt.

Der echte Hyper-V-Windows-/SQL-2025-Gastnachweis und der Zero-Touch-Cold-Path
bleiben verbindliche, parallel ausführbare Arbeiten. Sie blockieren die
Container-basierten Adapterpiloten nicht.

## 2. Begründung

1. Der Daseinszweck des Repositories ist die gemeinsame Ausführungsbasis für
   `SQL_PerformanceSchulung`, `SQL_Server_Analyze` und `SQL_Server_Toolbelt`.
   Ohne Adapter bleibt der implementierte Core für diese Projekte ungenutzt.
2. Ein früher Adapter validiert die öffentlichen Verträge (Manifest, State,
   Statuscodes, Sample-Handler) an realen Konsumenten, bevor `1.0`-Festlegungen
   entstehen.
3. Der native Hyper-V-Lifecycle ist bereits validiert. Die noch offene
   Image-/SQL-Gastabnahme profitiert weiterhin von stabilen,
   adaptererprobten Kernverträgen.
4. Die Container-Lane deckt die P0-Pilotkonstellationen des Master-Plans bereits
   ab; kein P0-Pilot benötigt zwingend Hyper-V.

Die Piloten beweisen zunächst den Adaptervertrag mit SQL Server 2025. Die
vollständige Entwicklungs- und Abnahmematrix von Analyze und Toolbelt umfasst
anschließend Windows und Linux mit SQL Server 2019, 2022 und 2025.

## 3. Arbeitspakete

| ID | Arbeitspaket | Inhalt | Abnahme | Stand |
|---|---|---|---|---|
| `ADP-001` | Adapterschema | `Schemas/project-adapter.schema.json` mit den Feldern aus Master-Plan Abschnitt 8.3 (`ContractVersion`, `ProjectId`, `Entrypoints.*`, `SecretInputs` ohne Werte, `DataClassification`, ...), Version `0.1-draft` | ein synthetischer Beispieladapter validiert; unbekannte Major-Version wird abgelehnt | umgesetzt 2026-08-01 (`Adapters/Examples/synthetic-demo/`) |
| `ADP-002` | Adapter-Resolver und ApplyAdapter | Adapter lokal binden (Checkout oder Paket), read-only Preflight-Entrypoint, `ApplyAdapter` ohne Lifecycle-Seiteneffekt | Frameworkupdate startet oder ersetzt keine Runtime-Ressource | umgesetzt 2026-08-01 (`Test-SqlServerLabAdapter`, `Install-SqlServerLabAdapter`; nur T-SQL-Entrypoints) |
| `ADP-003` | Pilot `SQL_PerformanceSchulung` | eine reproduzierbare Beispielumgebung über Adapter-Entrypoints auf einem aktuellen Linux-/SQL-2025-Container-Lab konstruieren; Windows oder andere Katalogversion nur bei Szenariobedarf (Master-Plan Welle 6, vertikaler Slice) | Beispielkonstruktion läuft end-to-end; Demo-Inhalt und -Cleanup bleiben im Schulungsrepository | umgesetzt und mit Docker sowie Podman validiert 2026-08-30; Partner-PRs [#40](https://github.com/gecompat/SQL_PerformanceSchulung/pull/40) und [#41](https://github.com/gecompat/SQL_PerformanceSchulung/pull/41), Stand `b9a1ac3` auf `origin/main` |
| `ADP-004` | Pilot `SQL_Server_Analyze` | Frameworkinstallation und ein Quick-Szenario über Adapter (Master-Plan Welle 7, vertikaler Slice) | Analyzer-Evidenz bleibt im Analyze-Repository; keine duplizierte Lifecycle-Logik; Ausbau zur Windows-/Linux-Matrix 2019/2022/2025 ist partnerseitig definiert | umgesetzt und mit Docker sowie Podman validiert 2026-08-30; Partner-PR [#112](https://github.com/gecompat/SQL_Server_Analyze/pull/112), Stand `45a9594` auf `origin/main` |
| `ADP-005` | Statische Adapter-Checks | Schema-, Beispiel- und Statuscode-Prüfungen unter `Tests/Static/` | Checks laufen lokal ohne Runtime | umgesetzt 2026-08-01 (`Invoke-ProjectAdapterChecks.ps1`) |
| `ADP-008` | Pilot `SQL_Server_Toolbelt` | ein versioniertes Toolbelt-Modul über Adapter-Entrypoints auf einem SQL-2025-Container-Lab installieren, validieren, aktualisieren und deinstallieren (Master-Plan Welle 7a, vertikaler Slice) | Modul-Lifecycle läuft end-to-end; Modulinhalt und Windows-/Linux-Mehrversions-Evidenz 2019/2022/2025 bleiben im Toolbelt-Repository | offen; benötigt Arbeit im Toolbelt-Repository |

Die Reihenfolge ist verbindlich: erst Vertrag (`ADP-001`/`ADP-002`), dann je ein
kleiner Pilot pro Partnerprojekt. Eine vollständige Migration der
Partnerprojekte (Master-Plan Welle 8) beginnt erst nach allen drei Piloten.

### 3.1 Evidence für `ADP-003`

`SQL_PerformanceSchulung` bindet `CON-004` über den Project Adapter `0.1` mit
getrennten T-SQL-Entrypoints für Preflight, Install, Validate und Cleanup. Der
öffentliche Schulungs-Lifecycle verwendet `Test-SqlServerLabAdapter` und
`Install-SqlServerLabAdapter`; Provider-, Run-State- und Infrastruktur-Cleanup
bleiben vollständig im Lab-Core.

Die lokalen Docker- und Podman-Läufe vom 2026-08-30 mit SQL Server 2025
(RunIds `30b69f0b-b140-47e6-8c90-c05e38bd7c99` und
`f80f7d82-934b-4c7c-9d2a-a80e975d92d5`) belegten jeweils:

- Start bis `READY_FOR_USER` einschließlich Adapter-Validate;
- markergebundenen Cleanup und erneute Installation beim Reset;
- erneutes `READY_FOR_USER` auf derselben Run-Instanz;
- fachlichen Cleanup sowie Container- und Volume-Abbau mit Endstatus
  `REMOVED`.

Alle statischen Partner-Validatoren, 15 Unit-Tests, das Lab-Adapterschema und
die PowerShell-Syntaxprüfung waren grün. Die elf Checks der beiden
Partner-PRs waren ebenfalls grün. Der Podman-Cleanup ließ eine fremde, bereits
vorhandene Containerressource unangetastet und entfernte das run-eigene Volume.
Im Pilot wurde keine generische Core-Lücke festgestellt und keine Providerlogik
in das Schulungsrepository kopiert.

### 3.2 Evidence für `ADP-004`

`SQL_Server_Analyze` bindet `EXECUTION-PLAN-001` über den Project Adapter `0.1`
mit getrennten T-SQL-Entrypoints für Preflight, Install, Update, Validate und
Cleanup. Der deterministisch aus 22 kanonischen SQL-Dateien erzeugte Installer
installiert ausschließlich den eigenständig unterstützten
Execution-Plan-Analyse-Frameworkteil. Szenario, synthetische Plan-Evidenz,
fachliche Assertion und markergebundener Datenbank-Cleanup bleiben vollständig
im Analyze-Repository.

Die lokalen Docker- und Podman-Läufe vom 2026-08-30 mit SQL Server 2025
(RunIds `1f275b55-fdb8-4f51-8e50-2b6883deffa8` und
`3a212dd9-43f1-4882-9d8a-1c283b80ea6f`) belegten jeweils:

- Provisionierung ausschließlich über öffentliche Lab-APIs;
- erfolgreiche Install-, Update- und Validate-Entrypoints;
- erfolgreiche Analyse eines synthetischen Ausführungsplans;
- markergebundenen Adapter-Cleanup;
- vollständigen Container- und Volume-Abbau mit Endstatus `REMOVED`.

Die statische Analyze-Vertragssuite mit 26 Prüfungen sowie die vier Checks des
Partner-PRs waren grün. Im Pilot wurde keine generische Core-Lücke festgestellt
und keine Providerlogik in das Analyze-Repository kopiert. Die breitere
Windows-/Linux-Mehrversionsmatrix bleibt partnerseitige Analyze-Evidenz.

## 4. Abhängigkeiten und Vorleistungen

- **Sample-Welle 4 (SQL-Skript-/Bundle-Handler):** Schulungsbeispiele und
  Toolbelt-Module installieren T-SQL-Inhalte. Eigene versionierte Entrypoints
  sind für die Piloten bevorzugt. Wird stattdessen ein generischer
  Script-Bundle-Handler benötigt, ist dessen enger Vertrag vor dem betroffenen
  Piloten umzusetzen.
- **Statuscode-Stabilität:** Adapter konsumieren strukturierte Statuscodes
  (`DATASET_READY`, `TRUST_REQUIRED`, `RECOVERY_REQUIRED`, ...). Änderungen an
  diesen Codes gelten ab jetzt als Breaking Change mit Migrationshinweis.
- **Kein CI/CD-Zwang:** Adapterprüfungen bleiben lokal ausführbar.

## 5. Nichtziele dieser Phase

- keine Scenario Engine und keine Fault Injection (Master-Plan Welle 5);
- keine Hyper-V-Provisionierung;
- keine Entfernung bestehender Funktionalität aus den Partnerprojekten vor
  reproduzierbarer Abnahme (Master-Plan Welle 8);
- keine `1.0`-Festschreibung der Verträge vor drei produktiven Adaptern.
