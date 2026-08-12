# Project-Adapter-Priorisierung

| Merkmal | Wert |
|---|---|
| Status | `PLANNING_DECISION` |
| Stand | 2026-08-12 |
| Bezieht sich auf | `MASTER_IMPLEMENTATION_PLAN.md` Wellen 4, 6, 7 und 7a |
| Runtime-Nachweis | ausschließlich `Documentation/Quality/KNOWN_LIMITATIONS.md` |

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
| `ADP-003` | Pilot `SQL_PerformanceSchulung` | eine reproduzierbare Beispielumgebung über Adapter-Entrypoints auf einem aktuellen Linux-/SQL-2025-Container-Lab konstruieren; Windows oder andere Katalogversion nur bei Szenariobedarf (Master-Plan Welle 6, vertikaler Slice) | Beispielkonstruktion läuft end-to-end; Demo-Inhalt und -Cleanup bleiben im Schulungsrepository | offen; benötigt Arbeit im Schulungsrepository |
| `ADP-004` | Pilot `SQL_Server_Analyze` | Frameworkinstallation und ein Quick-Szenario über Adapter (Master-Plan Welle 7, vertikaler Slice) | Analyzer-Evidenz bleibt im Analyze-Repository; keine duplizierte Lifecycle-Logik; Ausbau zur Windows-/Linux-Matrix 2019/2022/2025 ist partnerseitig definiert | offen; benötigt Arbeit im Analyze-Repository |
| `ADP-005` | Statische Adapter-Checks | Schema-, Beispiel- und Statuscode-Prüfungen unter `Tests/Static/` | Checks laufen lokal ohne Runtime | umgesetzt 2026-08-01 (`Invoke-ProjectAdapterChecks.ps1`) |
| `ADP-008` | Pilot `SQL_Server_Toolbelt` | ein versioniertes Toolbelt-Modul über Adapter-Entrypoints auf einem SQL-2025-Container-Lab installieren, validieren, aktualisieren und deinstallieren (Master-Plan Welle 7a, vertikaler Slice) | Modul-Lifecycle läuft end-to-end; Modulinhalt und Windows-/Linux-Mehrversions-Evidenz 2019/2022/2025 bleiben im Toolbelt-Repository | offen; benötigt Arbeit im Toolbelt-Repository |

Die Reihenfolge ist verbindlich: erst Vertrag (`ADP-001`/`ADP-002`), dann je ein
kleiner Pilot pro Partnerprojekt. Eine vollständige Migration der
Partnerprojekte (Master-Plan Welle 8) beginnt erst nach allen drei Piloten.

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
