# Project-Adapter-Priorisierung

| Merkmal | Wert |
|---|---|
| Status | `PLANNING_DECISION` |
| Stand | 2026-08-01 |
| Bezieht sich auf | `MASTER_IMPLEMENTATION_PLAN.md` Wellen 4, 6 und 7 |
| Runtime-Nachweis | ausschließlich `Documentation/Quality/KNOWN_LIMITATIONS.md` |

## 1. Entscheidung

Nach Abschluss der Sample-Welle 3 (Backup-Handler, Trust-Pfad, Mehrfachauswahl)
werden die **Project Adapter** (Master-Plan-Wellen 6 und 7) vor dem
Hyper-V-Provider (Master-Plan-Welle 4) umgesetzt.

Hyper-V bleibt verbindliches Ziel. Vorgezogen werden aus dem Hyper-V-Umfeld nur
die providerneutralen Vertragsanteile (Drives, Network Intents, Software,
Reconcile), soweit sie das Adapterdesign beeinflussen.

## 2. Begründung

1. Der Daseinszweck des Repositories ist die gemeinsame Ausführungsbasis für
   `SQL_Server_Analyze` und `SQL_PerformanceSchulung`. Ohne Adapter bleibt der
   implementierte Container-Core für beide Projekte ungenutzt.
2. Ein früher Adapter validiert die öffentlichen Verträge (Manifest, State,
   Statuscodes, Sample-Handler) an realen Konsumenten, bevor `1.0`-Festlegungen
   entstehen.
3. Hyper-V ist die aufwendigste Welle (Image-Pipeline, sealed VHDX, Netzwerke)
   und profitiert von stabilen, adaptererprobten Kernverträgen.
4. Die Container-Lane deckt die P0-Pilotkonstellationen des Master-Plans bereits
   ab; kein P0-Pilot benötigt zwingend Hyper-V.

## 3. Arbeitspakete

| ID | Arbeitspaket | Inhalt | Abnahme | Stand |
|---|---|---|---|---|
| `ADP-001` | Adapterschema | `Schemas/project-adapter.schema.json` mit den Feldern aus Master-Plan Abschnitt 8.3 (`ContractVersion`, `ProjectId`, `Entrypoints.*`, `SecretInputs` ohne Werte, `DataClassification`, ...), Version `0.1-draft` | ein synthetischer Beispieladapter validiert; unbekannte Major-Version wird abgelehnt | umgesetzt 2026-08-01 (`Adapters/Examples/synthetic-demo/`) |
| `ADP-002` | Adapter-Resolver und ApplyAdapter | Adapter lokal binden (Checkout oder Paket), read-only Preflight-Entrypoint, `ApplyAdapter` ohne Lifecycle-Seiteneffekt | Frameworkupdate startet oder ersetzt keine Runtime-Ressource | umgesetzt 2026-08-01 (`Test-SqlServerLabAdapter`, `Install-SqlServerLabAdapter`; nur T-SQL-Entrypoints) |
| `ADP-003` | Pilot `SQL_PerformanceSchulung` | eine grüne Pilotdemo über Adapter-Entrypoints auf einem Container-Lab (Master-Plan Welle 6, vertikaler Slice) | Demo läuft end-to-end; Demo-Cleanup bleibt im Schulungsrepository | offen; benötigt Arbeit im Schulungsrepository |
| `ADP-004` | Pilot `SQL_Server_Analyze` | Frameworkinstallation und ein Quick-Szenario über Adapter (Master-Plan Welle 7, vertikaler Slice) | Analyzer-Evidenz bleibt im Analyze-Repository; keine duplizierte Lifecycle-Logik | offen; benötigt Arbeit im Analyze-Repository |
| `ADP-005` | Statische Adapter-Checks | Schema-, Beispiel- und Statuscode-Prüfungen unter `Tests/Static/` | Checks laufen lokal ohne Runtime | umgesetzt 2026-08-01 (`Invoke-ProjectAdapterChecks.ps1`) |

Die Reihenfolge ist verbindlich: erst Vertrag (`ADP-001`/`ADP-002`), dann je ein
kleiner Pilot pro Quellprojekt. Eine vollständige Migration der Quellprojekte
(Master-Plan Welle 8) beginnt erst nach beiden Piloten.

## 4. Abhängigkeiten und Vorleistungen

- **Sample-Welle 4 (SQL-Skript-/Bundle-Handler):** Schulungsdemos installieren
  Frameworkobjekte über T-SQL. Entweder liefert der Adapter eigene
  Install-Entrypoints (bevorzugt für den Piloten) oder er nutzt den
  Script-Bundle-Handler; letzteres zieht Sample-Welle 4 vor `ADP-003`.
- **Statuscode-Stabilität:** Adapter konsumieren strukturierte Statuscodes
  (`DATASET_READY`, `TRUST_REQUIRED`, `RECOVERY_REQUIRED`, ...). Änderungen an
  diesen Codes gelten ab jetzt als Breaking Change mit Migrationshinweis.
- **Kein CI/CD-Zwang:** Adapterprüfungen bleiben lokal ausführbar.

## 5. Nichtziele dieser Phase

- keine Scenario Engine und keine Fault Injection (Master-Plan Welle 5);
- keine Hyper-V-Provisionierung;
- keine Entfernung bestehender Funktionalität aus den Quellprojekten vor
  reproduzierbarer Abnahme (Master-Plan Welle 8);
- keine `1.0`-Festschreibung der Verträge vor zwei produktiven Adaptern.
