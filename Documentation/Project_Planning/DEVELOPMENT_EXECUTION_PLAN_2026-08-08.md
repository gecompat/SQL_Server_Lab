# SQL Server Lab – konsolidierter Entwicklungs- und Ausführungsplan

| Merkmal | Wert |
|---|---|
| Projekt | `gecompat/SQL_Server_Lab` |
| Status | `PLANNING_BASELINE_FOR_IMPLEMENTATION` |
| Stand | 2026-08-08 |
| Ausgangsstand | `origin/main` = Commit `6411e5f` (`docs: integrate future workflow plan and readiness checks`); keine Commits zwischen `origin/main` und lokalem `HEAD` |
| Ziel | eine einzige ausführbare Lieferreihenfolge für Core, UI, Adapter, Hyper-V, Datenartefakte, Qualität und spätere Erweiterungen |
| Runtime-Nachweis | ausschließlich Code, passende Tests, [KNOWN_LIMITATIONS.md](../Quality/KNOWN_LIMITATIONS.md) und datierte Validierungsnachweise |

## 1. Zweck und Geltung

Dieser Plan konsolidiert die vorhandenen Master-, Architektur-, UI-,
Zero-Touch-, Adapter-, Qualitäts- und Backlog-Dokumente zu einer umsetzbaren
Entwicklungsreihenfolge. Er ersetzt keine bindende Architekturentscheidung,
sondern legt fest, **in welcher Reihenfolge** die offenen Ziele geliefert und
abgenommen werden.

Die vom Auftrag verwendete Bezeichnung `Codex_LAB` wird in diesem Dokument als
Arbeitskontext verstanden. Der tatsächliche Repository- und Produktname bleibt
`SQL_Server_Lab`.

### 1.1 Quellen und Vorrang

Bei Widersprüchen gilt folgende Reihenfolge:

1. [SQL-Server-zentrierte Scope-Entscheidung](../Architecture/SQL_SERVER_CENTRIC_SCOPE_DECISION.md) und [verbindliche Masterplan-Ergänzung](MASTER_IMPLEMENTATION_PLAN_SCOPE_ADDENDUM.md);
2. Security-, Privacy-, Lizenz-, State-, Ownership- und Cleanup-Verträge;
3. Code, Schemas, Kataloge und tatsächlich ausgeführte Tests als Ist-Nachweis;
4. [Bekannte Grenzen](../Quality/KNOWN_LIMITATIONS.md) als öffentliche Statuswahrheit;
5. bindende Architektur-Zielverträge;
6. dieser Plan für Priorität, Abhängigkeit und Lieferreihenfolge;
7. spezielle Backlogs für ausdrücklich vertagte Funktionen.

Planungsdokumente allein sind kein Runtime-Nachweis. `implemented` bedeutet,
dass Code und statischer Vertrag vorhanden sind. `validated` wird nur nach
einem tatsächlich erfolgreichen, passenden Lauf verwendet.

### 1.2 Verbindlich berücksichtigte Planungsquellen

- [Master-Umsetzungsplan](MASTER_IMPLEMENTATION_PLAN.md) einschließlich Wellenstatus;
- [Masterplan-Ergänzung](MASTER_IMPLEMENTATION_PLAN_SCOPE_ADDENDUM.md);
- [Project-Adapter-Priorisierung](PROJECT_ADAPTER_PRIORITIZATION.md);
- [Zukunftsplan der Menüführung](FUTURE_UI_WORKFLOW_PLAN_2026-08-08.md);
- [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](../Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md);
- [Testdatenbank- und Manifest-Wizard-Vertrag](../Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md);
- [Vorlagenpool und automatisierte Manifeste](../Architecture/TEMPLATE_POOL_AND_AUTOMATED_MANIFESTS.md);
- [Projektintegrationsvertrag](../Architecture/PROJECT_INTEGRATION_CONTRACT.md);
- [lokale Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md) und [Readiness-Checkliste](../Quality/LOCAL_READINESS_CHECKLIST.md);
- `.ai/PROJECT_CONTEXT.md`, `.ai/WORKING_RULES.md` und `.ai/repo_map.yaml`;
- der interne Zero-Touch-Handover für Hyper-V, insbesondere dessen nicht verhandelbare Anforderungen an unattended Provisionierung, Reconcile, Evaluation-Sicherheit und Cold-Path-Fallback.

## 2. Produktziel und unveränderliche Leitplanken

`SQL_Server_Lab` stellt lokale, isolierte, reproduzierbare und sicher
bereinigbare **SQL-Server-Testumgebungen** bereit. Zusätzliche Komponenten sind
nur zulässig, wenn sie einen dokumentierten SQL-Server-Zweck erfüllen.

Für jede Entwicklungswelle gelten folgende Leitplanken:

1. Docker, Podman und Hyper-V bleiben Kernprovider. Gleichrangigkeit im Zielvertrag bedeutet keine unbewiesene technische Gleichheit.
2. Das Manifest beschreibt den Desired State. UI und CLI sind Ansichten auf denselben Parser-, Planner-, State- und Runtime-Core.
3. Vor jeder Mutation existieren Resource Assessment, Cleanup-Plan, Scope/Owner/Run-ID und ein verständlicher Action Preview.
4. Jede Änderung an einem bestehenden Lab wird als `live`, `restart`, `recreate`, `reprovision` oder `unsupported` klassifiziert.
5. Nach Beginn einer normalen Provisionierung gibt es keine versteckten Benutzereingaben. Factory-, Trust-, Lizenz- und Diagnoseaktionen sind vorher getrennt auszuweisen.
6. Hyper-V-Parent-Images bleiben immutable und hashverifiziert. Normale Runs schreiben nur in Child-/Overlay- und run-lokale Datenträger.
7. Secrets erscheinen weder in Manifest, Lock, Plan, State, VM-Notes, Logs, Evidence noch im Repository.
8. Persistente Daten werden nur nach expliziter Policy behalten. Normales Cleanup entfernt niemals Testdatenbibliothek, Data Root oder Vorlagenpool.
9. Fehlende Capabilities führen zu `UNSUPPORTED`, `NOT_EXECUTED` oder einem expliziten Fallback, niemals zu stiller Simulation.
10. Produktfunktion und lokale Abnahme dürfen nicht von GitHub-hosted Runnern abhängen. Remote-Workflows sind zusätzliche Nachweise, keine Funktionsvoraussetzung.
11. Neue Manifestfelder gelten erst nach Übereinstimmung von Schema, Parser, Runtime, Beispiel, Dokumentation und Test als implementiert.
12. Eine neue öffentliche Funktion benötigt Implementierung, Export, Help, Benutzerreferenz und Test in derselben Welle.
13. `Quick`, `Scenario` und `Custom` sind Bedienansichten auf denselben Core und keine getrennten Lifecycle-Systeme.
14. Ressourcenunterversorgung darf nur bei `RESOURCE_INSUFFICIENT_OVERRIDABLE` bewusst und protokolliert übersteuert werden. Unsichere Pfade, fehlende Capabilities, blockierte Versionen, unzulässige Daten, fehlende Secrets/Lizenzen und ein fehlender Cleanup-Plan bleiben harte Blocker.
15. SQL-Versionen bleiben katalog- und constraintbasiert. `EXPERIMENTAL`, `SUPPORTED`, `DEPRECATED`, `RETIRED` und `BLOCKED` werden ohne Core-Neuentwurf verarbeitet.
16. Der Vorlagenpool überschreibt oder löscht keine Artifacts automatisch. Seine Kapazitäts- und Referenzschutzregeln bleiben erhalten.

## 3. Verifizierte Ausgangslage

### 3.1 Implementierte Grundlage

| Bereich | Aktueller belastbarer Stand |
|---|---|
| Container-Core | Docker und Podman mit Provisionierung, SQL Readiness, Datenbank, Skript, Restore, Lifecycle und scopegebundenem Cleanup |
| Providerbindung | bestehende Runs verwenden den im State gespeicherten Provider; gemischte Docker-/Podman-Runs besitzen getrennte `ProviderSubRuns` |
| Manifest | Ad-hoc- und unbeaufsichtigter Manifestpfad, externe Secret-Referenzen, Parser, Fachvalidierung und schema-gesteuerter Wizard |
| Datenartefakte | SHA-256, Trust Store, inhaltsadressierter Cache, Quarantäne, Run Lock, direkte `.bak`, sichere ZIP-/7z-Backup-Payload und gepinnte Einzelskripte |
| Samples | Mehrfachauswahl, Output-Kollisionsprüfung und `DATASET_READY`-Verifikation für freigegebene Handler |
| Project Adapter | Vertrag `0.1-draft`, sicherer Resolver, T-SQL-Entrypoints, Capability-/Versions-Gates und synthetischer Beispieladapter |
| Hyper-V-Basis | Generation 2, Secure Boot, Parent-/Child-VHDX, Image Registry, Builder, Zusatz-VHDX, Windows-Specialization, SQL-Readiness-Orchestrierung und scopegebundener Lifecycle |
| UI | interaktives PowerShell-Menü und lokale Loopback-Browseroberfläche mit Workflow-/Job-API |
| Qualität | statische Gesamtprüfung, Provider-Smokes, Versions-/Provider-Matrix, Restore-, Mixed-Provider-, Adapter- und Hyper-V-Testpfade |

Am 2026-08-08 wurde für diesen Plan erneut ausgeführt:

```text
.\Tests\Static\Invoke-AllChecks.ps1
=> ALLE STATISCHEN VERTRAGSPRUEFUNGEN: PASS
```

Die datierten Runtime-Ergebnisse stehen separat in
[VALIDATION_RESULT_2026-08-08.md](../Quality/VALIDATION_RESULT_2026-08-08.md).
Diese Planung hat keine Container- oder VM-Runtime mutiert.

### 3.2 Offene Kernlücken

| Lücke | Wirkung |
|---|---|
| Statusquellen sind teilweise zeitlich und fachlich asynchron | Prioritäten und Runtimeaussagen können falsch interpretiert werden |
| kein gemeinsamer Desired-State-/Actual-State-/Diff-/Plan-Vertrag | Reconcile und konsistente UI-Vorschau können nicht providerneutral wachsen |
| bestehende Hyper-V-Standardwege enthalten noch Factory-/manuelle Übergänge | ein normaler Lablauf ist noch nicht durchgehend Zero-Touch nachgewiesen |
| kein positiver realer Hyper-V-Cold-Path von generalisierter OS-Basis bis SQL `READY` für die Zielmatrix | Mocks und Lifecycle-Smoke beweisen weder OOBE- noch SQL-End-to-End-Bereitschaft |
| Hyper-V-Manifestbindung für freie Drives, Datenbanken, Post-Provisioning und Network Intents ist unvollständig | UI-/Manifestparität fehlt |
| Reconcile-Executor und Actual-State-Collector fehlen | vorhandene Labs können noch nicht über einen einheitlichen Änderungsplan verwaltet werden |
| zwei reale Adapterpiloten fehlen | der Vertrag ist noch nicht an beiden Primärkonsumenten bewiesen |
| Script Bundles, mehrere Handler-Outputs und `LAB_GENERATED`-Baselines sind offen | komplexere Schulungs-/Analysepakete benötigen Sonderwege |
| Fault-/Scenario-Engine, PSScriptAnalyzer-Baseline und vollständiger Privacy-Scanner fehlen | Release-Härtung und komplexe SQL-Szenarien bleiben unvollständig |

### 3.3 In Phase 0 zu reparierende Statusabweichungen

Die folgenden Punkte sind Planungsinput und dürfen nicht als bereits behoben
gelten:

- `LOCAL_VALIDATION_STRATEGY.md` behauptet in Abschnitt 7 noch, es gebe kein übergeordnetes Matrixskript, obwohl `Invoke-SmokeMatrix.ps1` existiert und dokumentiert ist.
- `.ai/PROJECT_CONTEXT.md` und `.ai/repo_map.yaml` enthalten einzelne ältere Aussagen zu Sample-Handlern und Hyper-V-Build-/Resume-Pfaden.
- `Documentation/README.md` nennt noch 17 öffentliche Funktionen, während `SqlServerLab.psd1` aktuell 19 Exporte enthält.
- `MASTER_IMPLEMENTATION_PLAN.md` führt den Wellenstatus nur mit Stand 2026-08-01.
- `FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md` besitzt eine ältere Prioritätstabelle, die der späteren Adapterentscheidung widerspricht.
- `FUTURE_UI_WORKFLOW_PLAN_2026-08-08.md` referenziert den privaten Zero-Touch-Plan mit einem zu prüfenden relativen Link.
- „CI/CD ist kein Bestandteil“ und die vorhandenen ergänzenden `.github/workflows` müssen einheitlich als **keine Produktabhängigkeit, aber optionale Remote-Validierung** beschrieben werden.
- die aktuelle Menüposition „Hyper-V-Umgebungen verwalten“ unter der Image-Verwaltung widerspricht dem langfristigen umgebungszentrierten Zielbild.

## 4. Verbindliche Produkt- und UX-Entscheidungen

### 4.1 Kanonischer Bedienpfad

Das künftige Hauptmenü wird nach Benutzeraufgaben gegliedert:

1. **Neue Umgebung erstellen**
2. **Bestehende Umgebung ändern**
3. **Umgebungen verwalten**
4. **Vorlagen und Installationsmedien verwalten**
5. **Erweitert und Diagnose**

Status, Start, Stop, Restart, Datenbanken, Skripte und Remove bleiben erreichbar,
werden jedoch im Bereich der ausgewählten Umgebung gebündelt. Während der
Migration dürfen die heutigen direkten Aktionen als Kompatibilitätsalias
bestehen bleiben.

Die Entscheidung aus dem UI-Entwurf wird damit aufgelöst: Die Verwaltung einer
normalen Umgebung gehört langfristig **nicht** in den Image-Builder-Pfad.
Factory- und Image-Aktionen bleiben getrennt unter Vorlagen/Medien oder
Erweitert. So bleiben der sichere Übergang und das umgebungszentrierte Zielbild
gleichzeitig erhalten.

### 4.2 Gemeinsames Änderungsmodell

```text
Desired State
    -> Preflight und Capability Resolution
    -> Actual State
    -> semantischer Diff
    -> Action Preview mit Änderungsklassen
    -> Bestätigung vor erster Mutation
    -> Operation Journal und Executor
    -> Postconditions
    -> State/Lock aktualisieren
    -> Ergebnis und Recovery-Status
```

Das Action-Preview-Objekt enthält mindestens:

- alte und neue Werte;
- Provider, Run-ID, Instance-ID und betroffene Ressourcenrollen;
- Änderungsklasse je Änderung und höchste Gesamtklasse;
- Downtime und erforderliche Reboots;
- Datenwirkung, Persistenz- und Migrationsweg;
- Trust-, Lizenz-, Exposure- und Sicherheitswarnungen;
- Cleanup-, Rollback- und Recovery-Pfad;
- erwartete Postconditions;
- Kennzeichnung, ob der Ablauf nach Bestätigung vollständig unattended ist.

### 4.3 Standard-, Infrastruktur- und Advanced-Pfad

| Pfad | Inhalt |
|---|---|
| Schnellpfad | Lifecycle, SQL-Status, Datenbank, Sample, Skript, sichere Defaults |
| Infrastruktur | CPU/RAM, Netzwerk, Storage, Persistenz, Reconcile und Downtime |
| Advanced | Host-Folder-Mounts, Factory, manuelle Diagnose, VMConnect, WMI-/Recovery-Werkzeuge |

Host-Folder-Mounts bleiben Spezialkonfiguration. Schreibzugriff benötigt weiter
den doppelten Opt-in im Manifest und im Aufruf. Hyper-V-VHDX und verwaltete
Container-Volumes gehören dagegen in den normalen Storage-Pfad.

## 5. Kritischer Lieferpfad

```mermaid
flowchart LR
    M0["M0 Statuswahrheit"] --> M1["M1 Desired State und Planner"]
    M1 --> M2["M2 UI-Shell und Container-Reconcile"]
    M2 --> M3["M3 zwei Adapterpiloten"]
    M3 --> M4["M4 Hyper-V OS Cold Path"]
    M4 --> M5["M5 Hyper-V SQL und Resolver"]
    M5 --> M6["M6 Reconcile-Breite und Infrastruktur-UI"]
    M6 --> M7["M7 Datenartefakte und Baselines"]
    M7 --> M8["M8 Szenarien und Migration"]
    M8 --> M9["M9 Release-Härtung"]
    M4 --> O1["Optional: Factory-Automation"]
    M5 --> O2["Optional: Warm Pool"]
    M9 --> O3["Später: Remote Host, CU-Monitoring, HA/Integration"]
```

Die Reihenfolge hält die dokumentierte Adapterpriorisierung ein. Providerneutrale
Desired-State-, Drive-, Network-, Software- und Reconcile-Verträge werden vor
den Adapterpiloten begonnen; der große Hyper-V-Runtimeausbau folgt nach dem
Vertragsbeweis durch beide Primärkonsumenten.

## 6. Meilensteine und Arbeitspakete

### 6.1 Priorität, Größenklasse und primäre Verantwortung

Größenklassen sind relative Planungswerte, keine Kalenderzusage. Eine zeitliche
Terminierung erfolgt erst, wenn Verantwortliche, reale Provider-Testfenster und
Arbeiten in den Schwester-Repositories verfügbar sind.

| Meilenstein | Priorität | Größe | Primäre Verantwortung | Harte Abhängigkeit |
|---|---:|---:|---|---|
| M0 Statuswahrheit | P0 | S | Dokumentation/Quality | keine |
| M1 Desired State und Planner | P0 | XL | Core/Contracts | M0 |
| M2 UI und Container-Reconcile | P0 | L | Core, UX, Docker/Podman | M1 |
| M3 Adapterpiloten | P0 | L | Integration plus Konsumenten | M2 und externe Scopes |
| M4 Hyper-V OS Cold Path | P0 | XL | Hyper-V/Windows | M1, M3, reale Baseline |
| M5 Hyper-V SQL und Resolver | P0 | XL | Hyper-V/SQL | M4, verifizierte Medien |
| M6 Reconcile-Breite | P1 | XL | Core, Hyper-V, Netzwerk, UX | M5 |
| M7 Artifacts und Baselines | P1 | L | Artifact/Data/Provider | M5, teilweise M6 |
| M8 Scenarios und Migration | P1 | XL | Scenario/Integration | M3, M6, M7 |
| M9 Release-Härtung | P1 | L | Quality/Release | M8 |

`P0` liefert den sicheren, konsumierbaren Kern. `P1` vervollständigt das
vereinbarte Kernvorhaben. `P2` optimiert oder erweitert nach erfolgreichem
Cold Path. `P3` bleibt entkoppelter Backlog.

### M0 – Statuswahrheit und planbare Baseline

**Ziel:** Alle Front-Door-, Planungs- und Qualitätsquellen beschreiben denselben
Ist-Stand und dieselbe Priorität.

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `BASE-001` | Code, Exporte, Schemas, Kataloge, Tests, Menüs und Provider-Metadaten inventarisieren | maschinenlesbare Capability-/Statusmatrix |
| `BASE-002` | die in Abschnitt 3.3 genannten Widersprüche und Links korrigieren | widerspruchsfreie Statuswahrheit |
| `BASE-003` | Master-Plan-Wellenstatus auf den aktuellen Stand bringen, ohne alte Zielentscheidungen umzuschreiben | aktuelle Mapping-Tabelle Alt-Welle -> neuer Meilenstein |
| `BASE-004` | Dokumentationschecks auf Planungsindex, relative Links und zentrale Statusaussagen erweitern | zukünftiger Drift wird testseitig sichtbar |
| `BASE-005` | lokale Testbefehle je Änderungsklasse und Evidence-Format vereinheitlichen | eine Readiness-Matrix ohne `SKIP == PASS` |

**Gate M0:**

- `Invoke-AllChecks.ps1` ist grün;
- Front Door, Known Limitations, Projektkontext und Repo-Map widersprechen einander nicht;
- jeder aktuelle Status ist `planned`, `implemented`, `validated` oder `unsupported`;
- keine Runtimefähigkeit wird nur aus einem Schema oder Mock abgeleitet.

### M1 – Desired State, Planner, Reconcile- und Recovery-Vertrag

**Ziel:** Ein providerneutraler, read-only planbarer Änderungsvertrag steht vor
jeder neuen UI- oder Runtimefunktion.

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `CORE-101` | Desired State, Actual State, Diff, Bound Plan, Lock und Result getrennt versionieren | stabile serialisierbare Verträge |
| `CORE-102` | Capability-Modell für Provider, OS, SQL, Netzwerk, Storage und Software | keine stille Gleichwertigkeitsannahme |
| `CORE-103` | Änderungsklassen `live`, `restart`, `recreate`, `reprovision`, `unsupported` | deterministische Klassifikation |
| `CORE-104` | Action Preview und `-WhatIf`/Planpfad ohne Mutation | identische Vorschau für CLI und UI |
| `CORE-105` | Operation Journal, Receipts, Reboot-Nachweis und idempotentes Resume | keine Doppelmutation nach Abbruch |
| `CORE-106` | Cleanup-/Recovery-Vertrag mit tatsächlichen IDs, Scope und Compensation | `RECOVERY_REQUIRED` statt unsichtbarer Reste |
| `CORE-107` | Evaluation-Ablauf, Mindestrestlaufzeit und Artifact-Kompatibilität im Resolver | ablaufende Baseline wird vor Mutation abgelehnt |
| `CORE-108` | Abwärtslesbarkeit bestehender Manifest-, Registry- und State-Daten | kein unnötiger Bruch bestehender Runs |
| `CORE-109` | öffentliche Recovery-Oberfläche für Resume, Recover und vollständiges Destroy gegen die bestehenden Lifecycle-Begriffe festlegen und implementieren | Addendum-Anforderung ohne doppeldeutige Cleanup-Commands |
| `CORE-110` | minimalen `SqlPurpose`-/Package-Vertrag und SQL-Version-Lifecycle statusfähig machen | Erweiterbarkeit bleibt SQL-zentriert |
| `CORE-111` | Resource-Assessment-Status und bewusstes Overcommit im Plan und State persistieren | Override bleibt sichtbar; Hard Blocks bleiben nicht übersteuerbar |

**Gate M1:**

- ein synthetisches vorhandenes Lab erzeugt read-only einen vollständigen No-op- oder Änderungsplan;
- Pool deaktiviert oder leer ist gültig und blockiert keinen Standardpfad;
- ohne Cleanup-Plan, bekannte Änderungsklasse oder erfüllte Capability beginnt keine Mutation;
- neue Vertragsversionen lehnen unbekannte Major-Versionen kontrolliert ab;
- Pläne, Locks und Results enthalten keine Secrets oder reale Hostwerte.

### M2 – Umgebungszentrierte UI-Shell und Container-Referenzimplementierung

**Ziel:** Das neue Bedien- und Reconcile-Modell wird zuerst an den bereits
produktiven Containerprovidern vertikal bewiesen.

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `UX-201` | Hauptmenü auf die fünf Benutzeraufgaben umstellen | Umgebung statt Builder als Einstieg |
| `UX-202` | Providerneutrales „Bestehende Umgebung ändern“ und „Umgebungen verwalten“ | einheitliche Auswahl und Metadaten |
| `UX-203` | Schnell-, Infrastruktur- und Advanced-Pfad umsetzen | Spezialaktionen bleiben sichtbar getrennt |
| `UX-204` | Browser-UI und PowerShell-Menü auf dieselben Workflow-/Planner-Results binden | keine Businesslogik-Duplikation in JavaScript |
| `UX-205` | alte direkte Menüaktionen als getestete Übergangsaliase erhalten | risikoarme Migration |
| `CNT-211` | Docker-/Podman-Actual-State-Collector | belastbarer Soll-/Ist-Vergleich |
| `CNT-212` | SQL-Konfiguration und unterstützte Limits live ändern | erster `live`-Nachweis |
| `CNT-213` | Ports, Mounts und Environment kontrolliert per Recreate ändern | persistente Volumes bleiben erhalten |
| `CNT-214` | Container-Volume-Verwaltung und Host-Mount-Schutz in Action Preview | Storage- und Safety-Parität |

**Gate M2:**

- No-op-Reconcile verändert keine Ressource;
- mindestens je ein realer `live`- und `recreate`-Fall ist auf Docker und Podman validiert;
- Providerbindung bleibt bei Status, Start, Stop, Reconcile und Cleanup erhalten;
- jede Mutation zeigt vorher Klasse, Downtime, Datenwirkung und Recovery;
- alte Menüpunkte und neue UI liefern fachlich dasselbe Resultatobjekt.

### M3 – Reale Project-Adapter-Piloten

**Ziel:** Der Lab-Core wird an beiden Primärkonsumenten bewiesen, bevor weitere
öffentliche Verträge oder eine Version `1.0` festgeschrieben werden.

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `ADP-003` | eine grüne `SQL_PerformanceSchulung`-Demo als Container-Vertical-Slice | Demo-End-to-End ohne kopierte Providerlogik |
| `ADP-004` | `SQL_Server_Analyze`-Frameworkinstallation plus ein Quick-/Diagnosefall | Analyzer-Evidenz bleibt im Konsumenten |
| `ADP-006` | Adapter-Preflight, Install/Update/Validate/Cleanup gegen Result- und Statusvertrag härten | strukturierte, versionsgebundene Integration |
| `ADP-007` | entscheiden, ob der Schulungspilot eigene T-SQL-Entrypoints genügt oder `script-bundle` vorzieht | keine unnötige Vorabimplementierung |

Arbeiten in den beiden Schwester-Repositories benötigen jeweils einen eigenen,
ausdrücklich abgestimmten Änderungsscope. Dieser Plan autorisiert keine
ungefragten externen Repositoryänderungen.

**Gate M3:**

- beide Piloten laufen reproduzierbar auf dem Container-Core;
- Adapter-Update startet, stoppt oder ersetzt keine Runtime-Ressource;
- Statuscodes und Capability-Gates sind konsumierbar;
- fachliche SQL-Inhalte, Assertions und Evidence bleiben im jeweiligen Projekt;
- keine Entfernung alter Pfade vor dokumentierter Parität und Übergangsfrist;
- noch keine Vertragsversion `1.0` ohne beide produktiven Piloten.

### M4 – Hyper-V Zero-Touch OS Cold Path

**Ziel:** Eine kompatible generalisierte Windows-Baseline wird ohne VMConnect
und ohne Gastinteraktion zu `OS_READY`.

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `HV-401` | `OS_GENERALIZED_SEALED` fachlich von älteren Artifactnamen abgrenzen und migrierbar lesen | klarer Factory-/Run-Vertrag |
| `HV-402` | run-spezifischen Unattend-Generator für unterstützte OS-Profile implementieren | Locale, Zeitzone, Konto, Computername und OOBE vollständig beschrieben |
| `HV-403` | Unattend ausschließlich offline in Child-VHDX injizieren und danach entfernen | Parent bleibt unverändert |
| `HV-404` | Elevation-, Mount-, Secret- und Pfad-Preflight fail-closed umsetzen | kein stiller manueller Fallback |
| `HV-405` | Child, Hardware, Labnetz, Boot, Reboot/Resume und Readiness orchestrieren | unattended Cold Path |
| `HV-406` | Heartbeat, PowerShell Direct, Identität, Locale, OOBE-Ende und Pending Reboot validieren | belastbarer `OS_READY`-Status |
| `HV-407` | parallele Child-VMs aus demselben Parent prüfen | keine Name-, IP-, Port- oder Identitätskollision |

Die einmalige Erstellung einer generalisierten Baseline darf in dieser Stufe
noch eine klar getrennte Factory-Aktion sein. Der normale Labpfad nach
vorhandener Baseline darf keine manuelle Gastaktion enthalten.

**Gate M4:**

- realer Referenzfall Windows Server 2025 erreicht `OS_READY` mit exakt null manuellen Gastinteraktionen;
- kein VMConnect-Aufruf ist für Erfolg erforderlich;
- Parent-Hash ist vor und nach dem Run identisch;
- Abbruch und Reboot sind resumierbar und erzeugen kein zweites Child;
- temporäre Unattend- und Secretartefakte sind entfernt;
- Cleanup entfernt nur run-lokale Ressourcen.

### M5 – Hyper-V SQL Cold Path, Prepared Accelerator und Manifestparität

**Ziel:** Der notwendige Fallback `OS_GENERALIZED_SEALED -> READY` funktioniert
ohne SQL-Vorlage; vorhandene Prepared-Images beschleunigen nur.

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `HV-501` | SQL-Medium, Edition, Features, Collation und Lizenzfähigkeit aus Katalog/Media Root auflösen | deterministischer SQL-Plan |
| `HV-502` | SQL Setup quiet/unattended mit Exitcode-, Timeout-, Reboot- und Receipt-Vertrag | idempotente Direktinstallation |
| `HV-503` | SQL Service, Major-Version, Edition, Features und Systemdatenbanken real prüfen | `SQL_READY` statt Setup-Erfolg allein |
| `HV-504` | TCP, WMI, Firewall, Authentifizierung und ausführbare SQL-Konfiguration anwenden | vollständige Run-Bereitschaft |
| `HV-505` | Datenbanken, Samples und Post-Provisioning über vorhandene Trust-/Artifact-Pfade binden | Manifestparität für den Vertical Slice |
| `HV-506` | vorhandenes `SQL_PREPARED_SEALED` und `CompleteImage` als optionalen Accelerator integrieren | schnellerer, nicht zwingender Pfad |
| `HV-507` | Resolver-Reihenfolge, Begründung und Cold-Path-Fallback umsetzen | Cache Miss blockiert nicht |
| `HV-508` | SQL 2025, danach 2022 und 2019 mit eigener Capability-/Medienabnahme testen | katalogbasierte Zielmatrix |

**Gate M5:**

- `OS_GENERALIZED_SEALED -> READY` funktioniert real ohne Prepared-Image und ohne Benutzereingriff;
- SQL-Setup-Reboot wird ohne Doppelinstallation fortgesetzt;
- Prepared-Image-Inkompatibilität führt begründet zum Cold Path;
- mindestens SQL Server 2025 ist real vollständig validiert; 2022/2019 sind validiert oder ausdrücklich `NOT_EXECUTED` mit Grund;
- Datenbank-/Sample-Verifikation und Cleanup sind erfolgreich;
- keine Secrets stehen in Setup-Logs, State, Lock oder Evidence.

### M6 – Hyper-V-Reconcile, Infrastrukturmenü und providerneutrale Network Intents

**Ziel:** Bestehende Hyper-V-Labs können über Desired-State-Änderungen sicher
und transparent verwaltet werden.

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `HV-601` | Actual State aus Hyper-V, Windows und SQL erfassen | semantischer Diff |
| `HV-602` | vCPU, statisches/dynamisches RAM und Min/Startup/Max umsetzen | `live`/`restart` nach Capability |
| `HV-603` | zusätzliche VHDX, Größenänderung und Rollen `Data`, `Log`, `TempDB`, `Backup` | Storage-Reconcile mit Gastverifikation |
| `NET-611` | Intents `isolated`, `hostOnly`, `nat`, `lan` mit Exposure Policy modellieren | providerneutraler Netzwerkvertrag |
| `NET-612` | IPAM, DHCP/static, DNS, Gateway, NIC/Switch und Kollisionen planen | deterministische Netzbindung |
| `HV-604` | SQL-Port, Memory, MaxDOP, ausgewählte Konfiguration und Testdatenbanken ändern | SQL-/Daten-Reconcile |
| `HV-605` | Recreate und Reprovision mit Backup/Restore, Neuvalidierung und spätem Alt-Cleanup | sicherer Datenübergang |
| `HV-606` | Host-Folder-Mount ausschließlich im Advanced-Pfad mit explizitem Risiko | Spezialfunktion ohne Defaultwirkung |
| `HV-607` | I/O-Intent `slow`, `throttled`, `balanced`, `high` capability-basiert auf VHDX-/Storage-Rollen binden | explizite, messbare Performance-Konstellation ohne falsches Benchmarkversprechen |
| `UX-621` | Hardware-, Netzwerk-, Storage-, SQL- und Reconcile-Untermenüs | vollständige Infrastrukturansicht |
| `UX-622` | Heatmap/Action Preview für `live` bis `reprovision` | verständliche Auswirkungsvorschau |

OS-, Edition- und inkompatible SQL-Versionswechsel werden zuerst als
`reprovision` behandelt. In-place-Upgrades benötigen später einen separaten,
ausdrücklich abgenommenen Vertrag.

**Gate M6:**

- je ein No-op-, Live-, Restart-, Recreate- und Reprovision-Szenario ist nachgewiesen;
- neue Umgebung wird bei Reprovision vor dem Alt-Cleanup vollständig validiert;
- persistente Daten bleiben erhalten und Downgrade wird abgelehnt;
- externe Switches und LAN-Exposure benötigen explizite Capability und Bestätigung;
- Bandbreiten-/Latenz- und I/O-Intents nennen Mechanismus, Zielrolle und Aussagegrenze;
- Host-Folder-Mount erscheint niemals im Standardpfad;
- UI, CLI, Manifest und Runtime verwenden dieselben Änderungsbegriffe.

### M7 – Datenartefakte, Baselines, Software und persistente Wiederverwendung

**Ziel:** Komplexere Projektinhalte und wiederverwendbare, verifizierte
Labzustände laufen über denselben Artifact-Vertrag.

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `DATA-701` | `script-bundle` mit `sqlcmd`, mehreren erwarteten Outputs und Verification | komplexe, reproduzierbare Sampleinstallation |
| `DATA-702` | Idempotency, Compensation und Teilfehler je Handler | kein halbfertiges `DATASET_READY` |
| `DATA-703` | `LAB_GENERATED`-Backup, Baseline Key, Registry und Verifikation | schneller zulässiger Folge-Run |
| `DATA-704` | Auswahl der besten kompatiblen Baseline, Invalidierung und Fallback | Cache bleibt optional |
| `DATA-705` | persistente Data-/Log-/Backup-Bereiche und Evaluation-Reprovision verbinden | kontrollierter Langzeitbetrieb |
| `DATA-706` | BACPAC, kontrollierte Archive und Attach nur als getrennte typisierte Verträge | keine Format-Uminterpretation |
| `DATA-707` | Artifact-Bindings für Docker, Podman und Hyper-V vereinheitlichen | Providerparität auf Vertragsebene |
| `SFT-711` | Softwarekatalog, Capability Resolver und providerneutrale Installationsreceipts | Software ist kein Hyper-V-Sondervertrag |
| `SFT-712` | Derived Container Images sowie unterstützte Windows-/Linux-Installationspfade für R, Python, Java und weitere SQL-bezogene Runtimes | reproduzierbare External-Runtime-Verifikation |

**Gate M7:**

- ein Bundle erzeugt mehrere erwartete Datenbanken und verifiziert sie;
- Fehler kompensieren vollständig oder enden sichtbar in `RECOVERY_REQUIRED`;
- eine `LAB_GENERATED`-Baseline wird bevorzugt und bei Inkompatibilität verworfen;
- Produktions-, unbekannte oder unverifizierte Daten bleiben blockiert;
- Resource Assessment berücksichtigt Download, Entpacken, Restore, Backup und Retention;
- Software wird nur bei SQL-Bezug installiert und über eine echte Postcondition validiert;
- normaler Cleanup berührt keine ausdrücklich persistenten Daten.

### M8 – Scenario Engine, Fault Injection und kontrollierte Migration

**Ziel:** Die fachlichen SQL-Szenarien der Primärkonsumenten nutzen den Core,
ohne eine zweite Labplattform zu erhalten.

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `SCN-801` | Scenario-, Workflow-, Probe-, Assertion- und Evidence-Verträge finalisieren | providerneutrale fachliche Abläufe |
| `SCN-802` | `Arrange`, `Act`, `Observe`, `Assert`, `Cleanup`, Timeouts und Abbruchsignale | resumierbare Scenario Engine |
| `FLT-811` | Netzwerk-, I/O-, CPU-, Memory-, TempDB- und Log-Faults capability- und scopegebunden | sichere Fault Injection |
| `FLT-812` | Ausgangszustand, automatische Rücknahme und Recovery verifizieren | kein unkontrollierter Restzustand |
| `MIG-821` | weitere grüne/gelbe/rote Schulungs- und Analyze-Piloten migrieren | fachliche Breite |
| `MIG-822` | Compatibility Wrapper, Deprecation und Paritätsnachweise | kontrollierter Übergang |
| `MIG-823` | generische Doppelimplementierungen erst nach Abnahme entfernen | kein Funktionsverlust |

**Gate M8:**

- mindestens ein Szenario läuft auf zwei kompatiblen Providern mit demselben fachlichen Vertrag;
- fehlende Capability ergibt `NOT_EXECUTED` oder `UNSUPPORTED`;
- mindestens ein Quick-, Diagnose-, Performance- und Fault-Szenario ist abgenommen;
- Fault-Cleanup ist nach Erfolg, Fehler und Abbruch nachgewiesen;
- fachliche SQL-Inhalte und Evidence verbleiben bei den Konsumenten;
- keine generische Lifecycle-Logik wird parallel weiterentwickelt.

### M9 – Release-Härtung und Abschluss des Kernvorhabens

**Ziel:** Lokal reproduzierbare Freigabe mit klaren Schnittstellen- und
Sicherheitsgarantien.

| ID | Arbeitspaket | Ergebnis |
|---|---|---|
| `QUAL-901` | Pester-Paket und projektspezifische PSScriptAnalyzer-Baseline | wartbare Unit-/Contract-Abdeckung |
| `QUAL-902` | Privacy-, Secret-, Pfad-, Symlink-/Junction- und Fremdobjektschutz erweitern | stärkere lokale Sicherheitsprüfung |
| `QUAL-903` | Fault Injection für Prozessabbruch, Reboot, Portbindung, Providerfehler und Cleanup | Recovery-Nachweis |
| `QUAL-904` | Release-Check, Versionierung, Notes und optionale hashgebundene Pakete | reproduzierbare lokale Freigabe |
| `QUAL-905` | Operator-, Recovery- und Troubleshooting-Dokumentation abschließen | sichere Bedienbarkeit ohne Chatkontext |
| `QUAL-906` | öffentliche Vertragsversion erst nach Adapter- und Providerabnahme festlegen | belastbare Kompatibilitätsgrenze |

**Gate M9:**

- vollständige lokale Freigabematrix ist grün oder jede nicht verfügbare Native-Prüfung ist als `NOT_EXECUTED` begründet;
- Releaseartefakte enthalten keinen State, Cache, Secret, Rohlog oder reale Environment Evidence;
- Recovery ist nach gezielt induzierten Teilfehlern deterministisch;
- eine neue Person kann Quick-, Manifest-, Adapter- und Hyper-V-Pfad sicher ausführen;
- die Gesamt-Definition-of-Done aus Abschnitt 13 ist erfüllt.

## 7. Nachgelagerte und ausdrücklich nicht blockierende Vorhaben

Diese Punkte bleiben erhalten, blockieren aber den kritischen Pfad nicht:

| Priorität | Vorhaben | Startbedingung |
|---|---|---|
| `P2` | vollautomatische Factory `MEDIA_VERIFIED -> OS_GENERALIZED_SEALED` | M4 Cold Path stabil; vorhandene Baseline genügt vorher |
| `P2` | `OS_READY_SLOT`/`SQL_READY_SLOT` Warm Pool | M5 Cold Path stabil; Poolfehler darf nur Geschwindigkeit beeinflussen |
| `P2` | Hyper-V Linux Vertical Slice | Windows-Hyper-V- und providerneutrale Verträge stabil |
| `P2` | Multi-Instanz, Domain Controller, Kerberos, WSFC, AG, FCI | konkreter SQL-Zweck, M8 Scenario-/Capability-Vertrag |
| `P2` | PolyBase/Hadoop, REST-/HTTP- und weitere Supporting Components | konkreter SQL-Integrationstest; kein allgemeines Fremdprodukt-Lab |
| `P3` | Remote Windows Hyper-V Host | registrierter Host, gehärtetes Remoting, separater Teilhost-State und kein implizites Credential Delegation |
| `P3` | CU-Monitoring | eigener kleiner Änderungssatz vom dann aktuellen `main`; Quellen und Schreibrechte neu prüfen |
| `P3` | zentrale Scheduler-, Cloud-, Kubernetes- oder allgemeine Remote-Agent-Architektur | nur nach konkretem SQL-Bedarf und neuer Architekturentscheidung |

## 8. Verbindliche Quality Gates je Änderungsklasse

| Änderung | Mindestprüfung |
|---|---|
| Dokumentation, Planung, Metadaten | `Invoke-AllChecks.ps1`; Links und Statuswahrheit gezielt prüfen |
| Manifest, Schema, Katalog | `Invoke-AllChecks.ps1` plus betroffene Manifest-/Resolver-/Handler-Checks |
| CLI oder Browser-UI | `Invoke-AllChecks.ps1`, `Invoke-WorkflowUiChecks.ps1`, gemeinsames Resultobjekt prüfen |
| Docker | statische Gesamtprüfung, Docker-Smoke, bei Restoreänderung Docker-Restore-Smoke |
| Podman | statische Gesamtprüfung, Podman-Smoke, bei Restoreänderung Podman-Restore-Smoke |
| gemeinsamer Container-Core | Docker- und Podman-Smoke, Restore für beide soweit betroffen, Mixed-Provider-Smoke und Matrix |
| Project Adapter | statische Adapterchecks und realer Adapter-Smoke; Lifecycle muss unverändert bleiben |
| Hyper-V Lifecycle/Builder | statische Gesamtprüfung und `Invoke-HyperVSmokeTest.ps1` in echter erhöhter Sitzung |
| Hyper-V OS/SQL Readiness | realer Windows-/SQL-Acceptance-Run; ein synthetischer Parent oder Mock reicht nicht |
| Reconcile | No-op sowie betroffene Klassen; Abbruch/Resume und Cleanup gezielt prüfen |
| Release | vollständige Provider-/Versions-/Parallelmatrix, Restore, Mixed Provider, Adapter und reale Hyper-V-Acceptance soweit freigegeben |

Empfohlener vollständiger Container-Releasepfad:

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
.\Tests\Integration\Invoke-MixedProviderSmokeTest.ps1
.\Tests\Integration\Invoke-SmokeMatrix.ps1 -Provider all -FullMatrix -IncludeParallel
```

Für Hyper-V-relevante Änderungen zusätzlich:

```powershell
.\Tests\Integration\Invoke-HyperVSmokeTest.ps1
.\Tests\Integration\Invoke-HyperVSqlAcceptanceRun.ps1
```

Der konkrete Acceptance-Aufruf richtet sich nach dessen Help und der lokal
freigegebenen, erhöhten Testumgebung. Reale Evidence bleibt lokal; versioniert
werden ausschließlich sanitisierte Statussummaries.

### 8.1 Ergebnisbegriffe

Erlaubte Prüfergebnisse sind:

```text
PASS
WARN
SKIP_OPTIONAL
NOT_EXECUTED
UNSUPPORTED
FAIL
RECOVERY_REQUIRED
```

Ein nicht verfügbarer Provider ist kein `PASS`. Ein erreichbarer, aber
fehlerhafter Provider ist `FAIL`. `PASS` setzt erforderliches Cleanup oder
einen ausdrücklich persistenten Endzustand voraus.

## 9. Liefer- und Pull-Request-Strategie

Jeder Änderungssatz liefert einen kleinen vertikalen Vertragsslice:

1. ein Ziel und eine Task-ID;
2. Schema/Contract, sofern betroffen;
3. Parser/Planner und Runtime;
4. State, Cleanup und Recovery;
5. CLI/UI nur über den gemeinsamen Core;
6. statische und passende Native-Tests;
7. Known Limitations, README/How-to und Repo-Map;
8. Changelog bei öffentlichem Verhalten;
9. Privacy- und Diff-Prüfung;
10. konkrete Liste ausgeführter und nicht ausgeführter Tests.

Unabhängige Features werden nicht in einen Pull Request gemischt. Eine Welle
darf aus mehreren kleinen Pull Requests bestehen, aber das jeweilige Gate wird
erst nach einem konsistenten vertikalen Stand geschlossen.

Von Codex erzeugte Commits verwenden eine englische erste Zeile mit dem Präfix
`Codex:`. Commit- und Pull-Request-Beschreibung nennen Scope, Auswirkungen,
Privacy-Prüfung sowie ausgeführte und nicht ausgeführte Tests.

### 9.1 Definition of Ready für ein Arbeitspaket

- autoritativer Zielvertrag und Task-ID sind benannt;
- Scope, Nichtziele und betroffene Provider sind klar;
- Überschneidungen mit offenen Branches/PRs wurden geprüft;
- Privacy-, Secret-, Lizenz- und Datenklassifikation sind geklärt;
- Resource-, State-, Cleanup- und Recovery-Wirkung ist bekannt;
- passende statische und Native-Abnahme ist ausführbar oder als externe Voraussetzung dokumentiert;
- ein sicherer Fallback oder ein fail-closed-Verhalten ist definiert.

### 9.2 Definition of Done für ein Arbeitspaket

- Code, Contract, Parser, Runtime und UI stimmen überein;
- keine Mutation beginnt ohne State und Cleanup-Plan;
- Idempotenz, Timeout, Fehlercode und Recovery sind getestet;
- kein Secret oder reale Environment Information ist versioniert;
- betroffene Provider wurden getrennt nachgewiesen;
- Dokumentation, Known Limitations, Repo-Map und Changelog sind synchron;
- nur tatsächlich ausgeführte Tests werden als bestanden ausgewiesen;
- der Branch-Diff enthält ausschließlich beabsichtigte Dateien.

## 10. Messbare Erfolgskennzahlen

| Kennzahl | Ziel |
|---|---|
| manuelle Gastinteraktionen im normalen Hyper-V-Labpfad | `0` |
| unerwartete Prompts nach erster Mutation | `0` |
| mutierende Aktionen mit Action Preview und Cleanup-Plan | `100 %` |
| Parent-Hash-Abweichungen nach normalen Runs | `0` |
| Secrets in versionierten oder portablen Artefakten | `0` |
| fremde Ressourcen durch Cleanup verändert | `0` |
| Provider-Smokes, die durch einen anderen Provider als bestanden gelten | `0` |
| Reconcile-No-op mit Mutation | `0` |
| reale Adapterpiloten vor Vertragsversion `1.0` | `2` |
| Statusaussagen ohne passenden Testnachweis | `0` |

Time-to-Ready für Container, Hyper-V-Cold-Path und optionale Accelerators wird
gemessen und getrennt berichtet. Vor reproduzierbaren Messdaten wird kein
verbindliches Performance-SLA festgelegt.

## 11. Hauptrisiken und Gegenmaßnahmen

| Risiko | Gegenmaßnahme |
|---|---|
| konkurrierende Wellenzählungen erzeugen falsche Reihenfolge | nur die Meilensteine dieses Plans als Ausführungsreihenfolge verwenden; Quelldokument-Wellen über Traceability zuordnen |
| UI läuft der Runtime voraus | UI rendert ausschließlich Planner-/Workflow-Results; keine Änderungslogik in JavaScript duplizieren |
| Hyper-V-Mocks werden als Zero-Touch-Nachweis missverstanden | reale OS-/SQL-Acceptance als eigenes Gate; klare Begriffe `implemented` und `validated` |
| Warm Pool verdeckt fehlerhaften Cold Path | Cold Path ohne Slots ist Pflichtprüfung; Fallback bleibt immer zulässig |
| OOBE bleibt versionsabhängig stehen | OS-spezifische Unattend-Profile, echter E2E-Test und fail-closed statt manueller Standardfallback |
| Reboot oder Prozessabbruch führt zu Doppelinstallation | persistente Receipts, neue Bootzeit, idempotentes Resume |
| Reprovision gefährdet Daten | neue Umgebung zuerst validieren, Backup/Restore, Downgrade ablehnen, Alt-Cleanup zuletzt |
| Host-Mount oder External Switch erweitert den Scope | Advanced-Pfad, doppelter Opt-in, Capability- und Exposure-Prüfung |
| Adapterarbeit dupliziert Providerlogik | harte Eigentumsgrenze und Lifecycle-Nebenwirkungsprüfung |
| Dokumentation driftet erneut | M0 erweitert statische Status-/Linkchecks; gekoppelte Dokumente je Task festlegen |
| lokaler Native-Test ist nicht verfügbar | `NOT_EXECUTED` mit Grund; keine grüne Ersatzbehauptung |

## 12. Empfohlene erste Änderungssätze

Die folgende Reihenfolge liefert frühe, einzeln prüfbare Ergebnisse:

1. `BASE-002`: Status- und Linkwidersprüche korrigieren.
2. `BASE-004`: Dokumentationschecks auf Planungs- und Statusquellen erweitern.
3. `CORE-101`/`CORE-103`: versionierte Desired-/Actual-/Diff- und Änderungsklassen definieren.
4. `CORE-104`: read-only Action Preview über die bestehende Workflow-API ausgeben.
5. `CNT-211`: Docker-/Podman-Actual-State ohne Mutation erfassen.
6. `UX-201`/`UX-202`: neuen umgebungszentrierten Einstieg mit alten Aliaspfaden hinzufügen.
7. `CNT-212`: erste reale Live-Änderung mit No-op- und Rollback-Test.
8. `CNT-213`: erste Recreate-Änderung mit persistentem Volume testen.
9. `ADP-003`: Schulungspilot in getrennt abgestimmtem Konsumenten-Scope.
10. `ADP-004`: Analyze-Pilot in getrennt abgestimmtem Konsumenten-Scope.
11. `HV-402`/`HV-403`: Unattend-Generator und sichere Child-Delivery.
12. `HV-405`/`HV-406`: realer Zero-Touch-OS-Cold-Path bis `OS_READY`.

Erst danach folgen SQL-Cold-Path, Resolver-Optimierung, breite
Hyper-V-Infrastrukturänderungen und optionale Caches.

## 13. Gesamt-Definition-of-Done

Das Kernvorhaben gilt als abgeschlossen, wenn:

1. Docker, Podman und Hyper-V denselben Desired-State-, Plan-, State- und Cleanup-Vertrag verwenden;
2. Quick-, Manifest-, UI- und nicht interaktive Aufrufe denselben Core nutzen;
3. beide Primärkonsumenten über produktive Adapterpiloten angebunden sind;
4. eine Hyper-V-Windows-SQL-Umgebung nach vorhandener generalisierter Baseline ohne Gastinteraktion `READY` erreicht;
5. SQL 2019, 2022 und 2025 katalogbasiert behandelt und je Capability korrekt validiert oder begründet nicht ausgeführt werden;
6. bestehende Labs über sichtbare `live`-, `restart`-, `recreate`- und `reprovision`-Pläne geändert werden können;
7. CPU, RAM, Dynamic Memory, Network Intents, VHDX-Rollen, SQL-Konfiguration und Testdatenbanken über Manifest, CLI und UI konsistent steuerbar sind;
8. persistente Daten bei Recreate/Reprovision nachweislich geschützt bleiben;
9. jeder Fehler einen deterministischen Cleanup-/Recovery-Pfad besitzt;
10. Parent-Images, fremde Ressourcen und nicht freigegebene Hostpfade unangetastet bleiben;
11. alle Secrets und lokalen Evidence-Daten außerhalb versionierter Artefakte bleiben;
12. Sample-/Bundle-/Baseline-Verträge die benötigten Projektinhalte reproduzierbar bereitstellen;
13. Scenario- und Fault-Pfade capability-, timeout- und scopegebunden sind;
14. lokale statische, Container-, Adapter- und Hyper-V-Abnahmen dokumentiert ausführbar sind;
15. Front Door, Known Limitations, Architektur, Tests und Repo-Map denselben Stand beschreiben;
16. Remote Host, Warm Pool, CU-Monitoring und weitere Supporting Components den Kernpfad nicht blockieren;
17. eine neue Person das Projekt ohne früheren Chatkontext sicher aufsetzen, bedienen, ändern und bereinigen kann.
