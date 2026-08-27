# Projektkontext

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Runtime-Status | `CONTAINER_CORE_IMPLEMENTED_HYPERV_SPECIALIZATION_READINESS_ORCHESTRATION` |
| Stand | 2026-08-20 |
| Repository | `gecompat/SQL_Server_Lab` |
| Maschinenlesbare Landkarte | [`repo_map.yaml`](repo_map.yaml) |

## 1. Ziel

`SQL_Server_Lab` ist die gemeinsame Plattform für lokale, isolierte und reproduzierbare SQL-Server-Testumgebungen.

Hauptanwendungsfälle:

- schnelle Ad-hoc-SQL-Server-Umgebung;
- deklarative Labdefinition per JSON-Manifest;
- Performance-Schulungsdemos;
- Analyse- und Diagnosekonstellationen;
- kontrollierte Last- und Fault-Szenarien;
- langfristig SQL-Server-Availability-, Security- und Integrationsszenarien.

SQL Server steht immer im Zentrum. Supporting Components wie Domain Controller, Hadoop-Cluster oder REST-Dienste sind nur zulässig, wenn sie einen dokumentierten SQL-Server-Zweck erfüllen.

## 2. Aktuelle Statuswahrheit

### Implementiert

- PowerShell-Modul und öffentliche Cmdlets;
- Docker-Provider;
- Podman-Provider;
- Ad-hoc- und Manifest-Provisionierung;
- SQL-Version- und CU-Buildauflösung aus dem Katalog;
- Resource Assessment;
- lokaler Run-State und Cleanup-Plan;
- SQL-Bereitschaft;
- Server- und Datenbankkonfiguration im dokumentierten Umfang;
- Datenbankerstellung;
- direkte `.bak`-Restores aus Datei oder URL;
- einmalige Trust-Auflösung, persistenter lokaler Trust Store,
  inhaltsadressierter Backup-Cache, Quarantäne und Run Lock für URL-Backups;
- Sample-Backup-Handler für executable `.bak`-Katalogvarianten mit
  Sample-Identität, Idempotenzregel und ONLINE-Verification;
- sichere `script-bundle`-Installation aus ZIP-Dateien mit root-gebundenem
  SQL-Entrypoint und mehreren erwarteten Outputs;
- inhaltsadressierte `LAB_GENERATED`-Baselines für Single- und Multi-Output-
  Container-Samples einschließlich kompatibler Aufsetzpunktauswahl;
- Mehrfachauswahl von Testdatenbanken im Ad-hoc-Menü und über
  `New-SqlServerLab -Sample`;
- gemischter Docker-/Podman-Lifecycle mit getrennten `ProviderSubRuns`;
- Post-Provision-T-SQL;
- Start, Stop, Restart, Status, Remove und Clear;
- read-only Desired/Actual/Diff-Reconcile sowie kontrollierte START-/STOP-
  Aktionen für bestehende Runs;
- verwalteter Storage-Vertrag, journalisierte Parent-Migration innerhalb eines
  Volumes und Cleanup-Audit;
- gemeinsames Console-UI-Framework für die umgesetzten CUI-001-bis-CUI-011-
  Flows;
- providerneutraler `SqlServerLab.Batch/1.0`- und
  `SqlServerLab.Operation/1.0`-Kern mit deterministischer Mengenexpansion,
  persistenter Queue, zwei Workern, einem `HyperVHeavy`-Slot, Resume,
  User-Gates, Queue-/Composer-Menü und Browserübergabe;
- statische Vertragsprüfung;
- Docker- und Podman-Smoke-Testpfad;
- providerneutraler Instanz-Autostart: Hyper-V `AutomaticStartAction`,
  Docker/Podman-Restart-Policy, Windows-Anmeldekoordinator und Podman-User-
  systemd-Service; der verwaltete CMS verwendet Autostart zwingend;
- Hyper-V-Lifecycle-Grundlage mit Generation 2, Secure Boot, verifizierter
  Parent-/Child-VHDX, Status, Start, Stop, deklarativem VM-Autostart und
  scopegebundenem Cleanup;
- immutable Hyper-V-Image-Registry mit SHA-256, sealed-Evidence,
  deterministischer Auswahl und portablem Manifest Lock;
- Windows-Image-Builder-Grundlage mit ISO-Integrity, persistentem Resume-State,
  Generation 2, Secure Boot, DVD-Boot und Manual-Action-Gate;
- buildgebundene Generalisierungsevidenz mit Challenge, VM-/Checkpoint-
  Postconditions und kontrollierter immutable Registry-Publikation;
- automatisches Windows-Sysprep ueber PowerShell Direct mit Microsoft-
  ImageState-Pruefung, resumierbarer Shutdown-Beobachtung und ohne persistierte
  Gast-Credentials;
- run-lokale dynamische oder feste Zusatz-VHDX mit SQL-bezogenen Drive-Rollen,
  SCSI-Anbindung, VM-Identitätsbindung und scope-validiertem Cleanup;
- stabile Zuordnung per VHDX-DiskIdentifier sowie resumierbare GPT-/NTFS-
  Initialisierungsorchestrierung im Windows-Gast über PowerShell Direct;
- Windows-Gastspezialisierung mit eindeutigem Computernamen, persistiertem
  Reboot-Zustand und begrenztem PowerShell-Direct-Reconnect;
- SQL-Readiness-Orchestrierung im Gast mit Dienst-, Major-Version- und
  Systemdatenbankprüfung sowie sanitierter `SQL_READY_RUN`-Evidenz;
- providerneutraler Softwarekatalog und External-Runtime-Resolver mit
  SQL-/OS-/Provider-Capability-Gates, sicherer Legacy-`post-start`-Grenze und
  geheimnisfreien Software-Intents für Python, R und Java;
- sicherer SQL-2022/Python-Derived-Image-Buildvertrag mit MCR-Basisdigest,
  vollständigen DEB-/Wheel-Locks, providerneutralem Image-Key, getrennten
  Docker-/Podman-Receipts, cgroup-v1-Preflight und scopebegrenzter
  `SYS_ADMIN`-Bindung; die positive Native Acceptance steht noch aus;

### Geplant oder unvollständig

- vollständiger Hyper-V-Provider mit resumierbarem OS-/SQL-Image-Build,
  SQL-`CompleteImage`, realem Gast-End-to-End-Nachweis, Manifest-Binding
  zusätzlicher Drives und providerneutralen Netzwerken;
- Hyper-V-SubRuns und ein providerübergreifendes Containernetzwerk innerhalb
  eines Runs;
- vollständige Ausführung aller im Schema vorbereiteten `serverConfig`-Felder;
- nicht freigegebene Archive und Attach-Szenarien;
- kontextreiche Manifest-Menüführung mit Navigation und Planvorschau;
- Hyper-V-Export und -Nutzung von `LAB_GENERATED`-Baselines;
- freigegebene External Runtimes einschließlich positiver Docker-/Podman-
  Native Acceptance, R-Derived-Image, Hyper-V-Gastinstallation,
  Java-Library-Registrierung und realer `sp_execute_external_script`-Nachweise;
- Reconcile-Aktionen über START/STOP hinaus, insbesondere für Ressourcen- und
  Konfigurationsänderungen;
- versionierter Refresh-/Rebuild-Lifecycle für Medien, VHDX und Container-Images;
- konsumierende Analyze- und Schulungs-Lab-Packages;
- langfristige Planner-, Package- und Supporting-Component-Architektur.
- Batch-/Queue-Provider-Matrix am 2026-08-20 real verifiziert: Docker und Podman mit je zwei SQL-2025-Runs, Hyper-V mit zwei Windows-2025-Slots, Resume und vollständigem Cleanup; offen bleiben echter Prozessabbruch, Manifest-Rerun und Windows-User-Gate
  einschließlich Abbruch- und Cleanup-Pfaden;

Die verbindliche Detailabgrenzung steht in `Documentation/Quality/KNOWN_LIMITATIONS.md`.

## 3. Provider

### Aktuelle Runtimeprovider

```text
Docker
Podman
```

Beide Provider benötigen getrennte Native-Tests. Ein erfolgreicher Docker-Test ist kein Podman-Nachweis und umgekehrt.

Der aktuelle Nachweis vom 2026-08-20 bestätigt Docker und Podman einschließlich
Batch-, paralleler, gemischter und Restore-Pfade. Der verbindliche Runtime-Gate des
Lab-Core verwendet SQL Server 2025 als einzige Referenzversion; reale
Mehrversions-Abnahmen liegen bei SQL Analyze und Toolbelt. Der erhöhte
GitHub-Runner und der lokale Batchnachweis bestätigen den nativen Hyper-V-
Lifecycle; die allgemeine echte SQL-2025-Acceptance aus frischer SQL-
Installationsmedia bleibt durch die fehlende Eval-ISO im Media-Root blockiert.
Die genaue Abgrenzung steht in
`Documentation/Quality/VALIDATION_RESULT_2026-08-20.md`.

Der Provider eines Runs wird in `connection-info.json` gespeichert. Lifecycle und Live-Status müssen diese Bindung verwenden und dürfen nicht zufällig eine andere lokal installierte Runtime auswählen.

### Partieller Runtimeprovider

```text
Hyper-V
```

Hyper-V besitzt einen getrennten VM-Lifecycle-Nachweis, aber noch keinen
positiven allgemeinen SQL-Runtime-Nachweis. Der Ad-hoc-Pfad bietet Hyper-V
deshalb nicht als allgemeinen SQL-Provider an. `New-SqlServerLab -Manifest`
kann nur den eng begrenzten Klonpfad aus genau einer veröffentlichten
`SQL_PREPARED_SEALED`-Vorlage verwenden; dieser Pfad ist kein Ersatz für den
noch offenen vollständigen End-to-End-Nachweis.

Der verbindliche Implementierungsvertrag steht in
`Documentation/Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md`.
Er definiert unter anderem sealed Images, SQL `PrepareImage`/`CompleteImage`,
Drives, Network Intents, Software, Manual Resume, Reconcile und Artifact Refresh.

## 4. SQL-Server-Versionen

SQL-Versionen werden über `Catalogs/sql-server-versions.json` aufgelöst.

Aktuelle Katalogeinträge:

- SQL Server 2019;
- SQL Server 2022;
- SQL Server 2025.

Die Produktjahre sind aktueller Katalogstand, keine dauerhafte Core-Grenze.

Unterstützte Bezeichner:

- Basisversion, beispielsweise `2022`;
- katalogisierter CU-Kurzbezeichner, beispielsweise `2022-CU16`;
- exakter Image-Tag, beispielsweise `2022-CU16-ubuntu-22.04`.

Unbekannte CU-Bezeichner werden nicht durch eine vermutete Tag-Konvention ersetzt.

Statuswerte:

```text
SUPPORTED
PREVIEW
DEPRECATED
RETIRED
BLOCKED
```

Der Katalog wird nicht automatisch als aktuell garantiert. Build- und CU-Angaben benötigen fachliche Verifikation.

## 5. Primärprojekte

- `gecompat/SQL_Server_Analyze`;
- `gecompat/SQL_PerformanceSchulung`;
- `gecompat/SQL_Server_Toolbelt`.

`SQL_PerformanceSchulung` nutzt standardmäßig eine aktuelle Linux-Umgebung zur
Konstruktion von Beispielen; einzelne Konstellationen dürfen Windows oder eine
andere katalogisierte SQL-Version anfordern. `SQL_Server_Analyze` und
`SQL_Server_Toolbelt` nutzen Windows und Linux mit SQL Server 2019, 2022 und
2025 für versionsabhängige Entwicklungs- und Abnahmetests. Alle drei Projekte
behalten ihre fachlichen Szenarien, Installationsinhalte, Testdaten, Workloads,
Beobachtungen und Assertions; `SQL_Server_Lab` stellt den generischen
Umgebungs- und Lifecyclepfad bereit und validiert seinen Core je Provider mit
SQL Server 2025.

Quell-Snapshots unter `_QuellRepo/` dienen nur als eingefrorene Referenz. Sie definieren nicht automatisch die öffentliche API dieses Repositories.

## 6. Autoritative Quellen

| Aussage | Quelle |
|---|---|
| exportierte Funktionen | `SqlServerLab.psd1` |
| Modul-Ladevorgang | `SqlServerLab.psm1` |
| Manifeststruktur | `Schemas/lab-manifest.schema.json` |
| Manifestauflösung | `Private/ManifestParser.ps1` |
| SQL-Versionen, Builds und Profile | `Catalogs/sql-server-versions.json` |
| Sample-Datenbanken | `Catalogs/sample-databases.json` |
| Providerimplementierung | `Providers/*/*.ps1` |
| State | `Private/StateMachine.ps1` |
| Cleanup | `Private/CleanupEngine.ps1` |
| Runtimegrenzen | `Documentation/Quality/KNOWN_LIMITATIONS.md` |
| Zielvertrag für Testdatenbank-Artefakte und Manifest-Wizard | `Documentation/Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md` |
| Zielvertrag für Hyper-V, Images, Netzwerke und Reconcile | `Documentation/Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md` |
| Benutzerfluss | `README.md`, `Documentation/User/Getting_Started.md` |
| KI-Landkarte | `.ai/repo_map.yaml` |
| statische Prüfung | `Tests/Static/Invoke-DocumentationChecks.ps1` |

Planungsdokumente sind keine autoritative Quelle für aktuellen Implementierungsstatus.

## 7. Aktueller Provisionierungsfluss

```text
Manifest oder Ad-hoc-Parameter
  -> Versionsprüfung
  -> Resource Assessment
  -> Run-State
  -> Cleanup-Plan
  -> Provider-Provisionierung
  -> SQL Readiness
  -> Serverkonfiguration
  -> CREATE DATABASE oder RESTORE
  -> Datenbankoptionen
  -> PostProvision-Skripte
  -> connection-info.json
  -> RUNNING
```

Restore- und Sample-Datenbanken werden nicht vorab per `CREATE DATABASE` angelegt.

## 8. Manifestvertrag

Ein Feld gilt erst als implementiert, wenn folgende Ebenen übereinstimmen:

1. JSON-Schema;
2. Manifestparser;
3. Runtimefunktion;
4. ausführbares Beispiel;
5. Dokumentation und Known Limitations;
6. passende Prüfung.

Ein Schemafeld allein ist kein Runtime-Nachweis.

Relative Pfade werden im Manifestparser aufgelöst:

- lokale Restorequelle relativ zum Manifest;
- `drives[].hostPath` relativ zum Manifest;
- `postProvision` relativ zum Manifest.

Data-, Log- und TempDB-Dateipfade sind Containerpfade.

## 9. Datenbankartefakte

Zulässig:

- im Lab erzeugte Backups zulässiger Labdatenbanken;
- öffentliche Demo- und Beispieldatenbanken mit dokumentierter Quelle und Lizenz;
- ausdrücklich klassifizierte lokale Entwicklungs-, Test- oder Lab-Backups.

Blockiert:

- Produktionsbackups;
- aus Produktivsystemen extrahierte reale Daten;
- unbekannte oder unklassifizierte Backups;
- automatische Übernahme lokaler Backups in GitHub- oder Downloadartefakte.

Der aktuelle Restorepfad unterstützt direkte `.bak`-Dateien. Archive, Attach-Szenarien und Backupketten benötigen einen eigenen zukünftigen Vertrag.

Der verbindliche Zielvertrag für mehrere auswählbare Samples, SQL-Skript- und
Bundle-Installationen, einmalige Vertrauensfreigabe mit dauerhaftem SHA-256,
portable sanitisierte Locks und `LAB_GENERATED`-Baselines steht in
`Documentation/Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md`.
Mehrfachauswahl, Trust-/Hash-Pfad und gepinnte Einzelskripte sind implementiert;
sichere Script Bundles, mehrere erwartete Outputs und containerbasierte
`LAB_GENERATED`-Baselines sind ebenfalls implementiert. Attach-Szenarien,
nicht freigegebene Archive und der Hyper-V-Baseline-Export bleiben offen.

## 10. State, Secrets und Cleanup

State liegt außerhalb des Git-Checkouts:

- Windows: `%LOCALAPPDATA%\SqlServerLab`;
- Linux/macOS: `~/.sql-server-lab`;
- Override: `SQL_SERVER_LAB_STATE`.

Pro Run entstehen mindestens:

- `run-state.json`;
- `cleanup-plan.json`;
- `connection-info.json`;
- lokale Secretdateien.

Vor der ersten Provider-Mutation müssen State und Cleanup-Plan existieren. Cleanup verwendet Scope, Labels und tatsächliche Ressourceninformationen, nicht bloß Namen.

Runtime-State, Secrets, Connection Information, konkrete Pfade und Cache-Dateien bleiben lokal und dürfen nicht versioniert werden.

## 11. Privacy

In Repository-, GitHub-, Package- und Downloadartefakten sind verboten:

- reale Personen-, Benutzer-, Kunden-, Firmen- und Organisationsdaten;
- reale Host-, Netzwerk-, Endpoint- und Pfadinformationen;
- reale Datenbank- und Objektstrukturen aus Produktivsystemen;
- Secrets, Tokens, Connection Strings und private Schlüssel;
- reale Logs, Plans, Responses, Screenshots und Diagnoseexports;
- Produktionsbackups oder unklassifizierte Datenbankartefakte.

Öffentliche, bereits freigegebene Projekt- und Attributionseinträge bleiben zulässig:

```text
gecompat - Gerhard Pisch
```

Bei unklarer Klassifikation wird vor Datei- oder Git-Operationen angehalten.

## 12. Sprache und Lizenz

- Dokumentation: Deutsch;
- etablierte englische Fachbegriffe bleiben erhalten;
- JSON-Felder, IDs, Codes und PowerShell-Parameter: Englisch;
- `LICENCE.md` ist maßgeblich;
- das Projekt ist nicht Open Source.

## 13. Validierung

Statisch:

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Static\Invoke-BatchWorkflowChecks.ps1
```

Docker:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
```

Podman:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

Nicht ausgeführte Native-Tests werden nicht als bestanden dargestellt.

## 14. Änderungsregel

Bei jeder Änderung sind die gekoppelten Dateien aus `.ai/repo_map.yaml` und `CONTRIBUTING.md` zu prüfen.

Insbesondere:

- keine neue öffentliche Funktion ohne Implementierung, Export, Doku und Test;
- kein neues Manifestfeld nur im Schema;
- keine Provideränderung ohne eigenen Provider-Nachweis;
- keine Katalogänderung ohne Schema- und Auflösungsprüfung;
- keine Statusaussage ohne Code- und Testnachweis.

## 15. Statuswahrheit

Eine Funktion darf erst als implementiert bezeichnet werden, wenn der Code vorhanden ist und eine passende lokale Prüfung existiert. Eine Funktion darf erst als validiert bezeichnet werden, wenn die relevante Prüfung tatsächlich erfolgreich ausgeführt wurde.

## 16. KI-Handover: Zero-Touch-Hyper-V (Stand 2026-08-08)

Für den nahtlosen Weitbetrieb gilt:

- Eine Erstellung neuer Hyper-V-Umgebungen darf im Standardpfad keine manuelle Gastinteraktion benötigen.
- CPU, RAM, Netzwerk und Drive-Topologie sind über Manifest, CLI und UI als deklarative Ziele konfigurierbar und im Reconcile änderbar.
- Speicherorte für TempDB, Daten, Log und Backup müssen im Manifest auswählbar sein und nachträglich geändert werden können.
- Testdatenbanken müssen in nachfolgenden Runs ergänzt oder entfernt werden können.
- Evaluation-OS mit Ablaufzeiten müssen vor Auswahl eines Aufsetzpunkts geprüft werden; ungültige oder ablaufende Baselines werden vorab ausgeschlossen.
- Speed bleibt Ziel: Cold-Path (OS_GENERALIZED_SEALED -> Child -> Unattend -> OS_READY) bleibt funktional korrekt und fallback-fähig, Pools/Acceleratoren bleiben optional.
- Nächster KI-Einstiegspunkt: die vorhandene Datei  
  `private_Note/SQL_Server_Lab_HyperV_Workflow_2026-08-08_1108Z_Zero_Touch_Plan.md`, insbesondere Abschnitt 24.

## 17. Operative Einbringung und Hygiene

- Konsistente Wellen werden mit kleinem Scope umgesetzt und **in die aktuelle `main`-Linie gemerged**.
- Nicht mehr benötigte PRs sind zu schließen oder zu löschen, um den Projektzustand zu säubern.
- Commitnachrichten richten sich nach den Projektregeln mit KI-Präfix in der ersten Zeile und klarer Änderungsbeschreibung.
- Branches, deren PRs abgeschlossen sind oder verworfen wurden, sind zeitnah aufzuräumen.
