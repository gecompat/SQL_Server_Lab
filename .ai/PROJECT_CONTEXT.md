# Projektkontext

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Runtime-Status | `CONTAINER_CORE_IMPLEMENTED` |
| Stand | 2026-07-30 |
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
- Mehrfachauswahl von Testdatenbanken im Ad-hoc-Menü und über
  `New-SqlServerLab -Sample`;
- Post-Provision-T-SQL;
- Start, Stop, Restart, Status, Remove und Clear;
- statische Vertragsprüfung;
- Docker- und Podman-Smoke-Testpfad.

### Geplant oder unvollständig

- Hyper-V-Provider mit resumierbarer OS-/SQL-Image-Pipeline, sealed
  Parent-VHDX, zusätzlichen Drives und providerneutralen Netzwerken;
- gemeinsamer Lifecycle für gemischte Provider innerhalb eines Runs;
- vollständige Ausführung aller im Schema vorbereiteten `serverConfig`-Felder;
- automatische Verarbeitung von Sample-Archiven, Attach-Szenarien und SQL-Skript-Samples;
- kontextreiche Manifest-Menüführung mit Navigation und Planvorschau;
- `LAB_GENERATED`-Baselines und deterministische Wahl des besten kompatiblen Aufsetzpunkts;
- providerneutrale Software und External Runtimes einschließlich Python unter
  Linux sowie Derived Container Images;
- kontrollierte nachträgliche Änderungen über Diff und Reconcile;
- versionierter Refresh-/Rebuild-Lifecycle für Medien, VHDX und Container-Images;
- konsumierende Analyze- und Schulungs-Lab-Packages;
- langfristige Planner-, Package- und Supporting-Component-Architektur.

Die verbindliche Detailabgrenzung steht in `Documentation/Quality/KNOWN_LIMITATIONS.md`.

## 3. Provider

### Aktuelle Runtimeprovider

```text
Docker
Podman
```

Beide Provider benötigen getrennte Native-Tests. Ein erfolgreicher Docker-Test ist kein Podman-Nachweis und umgekehrt.

Der Provider eines Runs wird in `connection-info.json` gespeichert. Lifecycle und Live-Status müssen diese Bindung verwenden und dürfen nicht zufällig eine andere lokal installierte Runtime auswählen.

### Roadmapprovider

```text
Hyper-V
```

Hyper-V ist ein verbindliches langfristiges Ziel, aber kein aktueller Runtime-Nachweis. Ein Verzeichnis oder Planungsdokument reicht nicht, um einen Provider als implementiert zu bezeichnen.

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
- `gecompat/SQL_PerformanceSchulung`.

Diese Projekte behalten ihre fachlichen Szenarien, Installationsinhalte, Testdaten, Workloads, Beobachtungen und Assertions. `SQL_Server_Lab` stellt den generischen Umgebungs- und Lifecyclepfad bereit.

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

Der verbindliche Zielvertrag für mehrere auswählbare Samples, SQL-Skript-/Bundle-Installationen, einmalige Vertrauensfreigabe mit dauerhaftem SHA-256, portable sanitisierten Locks und `LAB_GENERATED`-Baselines steht in `Documentation/Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md`. Diese Funktionen sind noch nicht implementiert.

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
