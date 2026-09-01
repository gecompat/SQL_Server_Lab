# Projektkontext

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Runtime-Status | `CONTAINER_CORE_IMPLEMENTED_HYPERV_SQL_CLI_ACCEPTED` |
| Stand | 2026-08-31 |
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
  Container- und run-gebundene Hyper-V-Samples einschließlich kompatibler
  Aufsetzpunktauswahl; Hyper-V exportiert nur aus der verifizierten Backup-
  Lane und entfernt die temporäre Gastkopie; ad-hoc CREATE/RESTORE nutzt bei
  fehlender expliziter Datenbankregel nur die verifizierten Default-Lanes;
- Mehrfachauswahl von Testdatenbanken im Ad-hoc-Menü und über
  `New-SqlServerLab -Sample`;
- gemischter Docker-/Podman-Lifecycle mit getrennten `ProviderSubRuns`;
- Post-Provision-T-SQL;
- Start, Stop, Restart, Status, Remove und Clear;
- read-only Desired/Actual/Diff-Reconcile, kontrollierte START-/STOP-Aktionen
  sowie journalisierter Container-Reconcile für CPU, RAM, SQL `max server
  memory`, Hostport, Autostart und External Runtimes einschließlich No-op,
  Rollback, Persistenz und Recovery; Hyper-V besitzt zusätzlich einen
  hostwertfreien Netzwerkplan und einen eng begrenzten journalisierten Executor
  für additive gebundene Hostinfrastruktur und genau einen vorhandenen
  getrennten VM-Adapter sowie getrennte vCPU-/RAM-, Grow-only-Storage-,
  SQL-Storage- und SQL-Konfigurations-Reconcile-Verträge mit Live- oder
  SQL-Dienstrestart-Klassifizierung;
- verwalteter Multi-Root-Storage-Vertrag mit stabilen `LocationId`-Werten,
  Backing-Device-Topologie, dateigenauem Storage-Plan, journalisierter
  Parent-Migration und Cleanup-Audit; dessen versioniertes read-only
  Storage-Residency-Inventar trennt `Lab_Data`, native Docker-/Podman-Ablage,
  externe Hostpfade, rungebundene sowie retained Objekte und unbekanntes
  physisches Runtime-Backing; der bindende
  `SqlServerLab.LabDataResidencyDecision/1.0`-Entscheid definiert `Lab_Data` als
  hostseitigen Katalog-, Austausch- und Recovery-Root, erlaubt katalogisierte
  native Container-Instanzstores und verbietet stille Eingriffe in globale
  Runtime-/Machine-Ablagen; der read-only Vertrag
  `SqlServerLab.PersistentStorageCatalog/1.0` ergänzt stabile, vom Anzeigenamen
  und Runtime-Namen unabhängige IDs, Klassen, Zustände, Referenzen und exklusive
  Leases, während `SqlServerLab.PersistentStoragePlan/1.0` Katalogbindungen,
  Konflikte und ID-lose Registrierungskandidaten ohne Mutation ausweist; der
  read-only Removal-Vertrag plant Retention, verifizierte Backup-/Package-
  Evidence, externe Bindungsfreigabe und Recovery-Gates und lässt endgültige
  Löschung persistenter Stores ausdrücklich außerhalb des Run-Cleanups; der
  PSR-005-Core wählt detached Docker-/Podman-Instanzstores per stabiler ID und
  Runtime-Label, liefert Continue-Bindings und klont die Quelle read-only mit
  Digest-Postcondition und wiederaufnehmbarem Journal; Docker und Podman sind
  getrennt live belegt, während Katalog-Commit und öffentliche Bedienung offen
  bleiben;
- versionierte `SqlServerLab.HyperVResourceBinding/1.0`-Grundlage mit kurzen,
  state-root-unabhängigen Create-Roots unter registriertem `Lab_Data`,
  Controller-/Location-/Volume-Revalidierung und getrennter read-only
  Legacy-Discovery; Slot-Provider, Windows-/SQL-Builder einschließlich der
  state-root-unabhängigen Auflösung persistierter Builder-VHDX,
  Existing-VM-Kopie,
  Image- und Staging-Store erzwingen die Bindung einschließlich Path-Length-,
  Reparse-, Datei-, VHDX- und VM-Pfad-Postconditions; ein read-only
  Legacy-Inventar und eine journalisierte, resumierbare Run-Migration binden
  VM-State und run-lokale VHDX erst nach Hash-, Identitäts-, Checkpoint-,
  Kapazitäts- und Readiness-Prüfung um und erhalten externe SQL-Lanes; der
  getrennte Image-Migrationsvertrag veröffentlicht Legacy-Artefakte
  hashidentisch im gebundenen Store und bewahrt referenzierte Quellen bis zu
  einem consumerfreien Resume-Cleanup; migrierte Runs lösen Legacy-Parents nur
  über diesen verifizierten Vertrag auf, journalisieren `Set-VHD` vorab,
  belegen getrennte Child-Hashes und setzen den Image-Cleanup automatisch fort;
  die reale laufende SQL-2022-Legacy-Migration bestätigte committed Binding,
  zwei Gast-/SQL-Restarts, Wiederherstellung des laufenden Zustands sowie
  vollständigen Kandidaten-/State-Cleanup bei abschließend 6/6 bereiter
  geschützter Testgruppe;
- öffentliche, read-only Hyper-V-Ressourcenzielvorschau mit registrierter
  Location, `Lab_Data`, freiem Speicher und klassenbezogenen Run-/Build-/Image-/
  Staging-/Recovery-Roots; das Console-User-Gate zeigt dieselbe Bindung vor
  UAC und der erhöhte Prozess revalidiert den explizit übergebenen Vertrag;
- gemeinsames Console-UI-Framework einschließlich der CUI-001-bis-CUI-020-
  Verträge: alle bekannten Optionslisten in Storage, Connection Center,
  Erstellungs- und Hyper-V-Pfaden verwenden stabile Menü-IDs, Cursor/Fallback
  und einheitliches `Escape`; ein statisches Inventar blockiert neue direkte
  `Read-Host`-Auswahlprompts;
- providerneutraler `SqlServerLab.Batch/1.0`- und
  `SqlServerLab.Operation/1.0`-Kern mit deterministischer Mengenexpansion,
  persistenter Queue, zwei Workern, einem `HyperVHeavy`-Slot, Resume,
  User-Gates, Queue-/Composer-Menü und Browserübergabe; harter
  Scheduler-Abbruch, Manifest-Rerun und reales Windows-User-Gate sind mit
  Resume und scopegebundenem Cleanup belegt;
- statische Vertragsprüfung;
- Docker- und Podman-Smoke-Testpfad;
- drei reale Project-Adapter-Piloten für `SQL_PerformanceSchulung`,
  `SQL_Server_Analyze` und `SQL_Server_Toolbelt`; alle drei durchliefen ihren
  SQL-Server-2025-Linux-Referenzfall getrennt unter Docker und Podman
  end-to-end einschließlich scopegebundenem Cleanup;
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
- realer Windows-Server-2025-/SQL-Server-2025-Pfad vom hashverifizierten
  Prepared-Image-Build über `PrepareImage`, Sysprep und immutable Publikation
  bis zum normalen differenzierenden Manifest-Klon mit `CompleteImage`,
  `SQL_READY_RUN`, unverändertem Parent-Hash und vollständigem Cleanup;
- echter Hyper-V-SQL-2025-CLI-Vertical-Slice mit Installation, Storage,
  TempDB, Ressourcenwechsel, Datenpersistenz und Cleanup;
- realer Hyper-V-N5-Mehrgerätepfad mit vier TempDB-Datendateien in
  2/1/1-Verteilung auf drei nachweislich getrennten lokalen Geräten, eigener
  TempDB-Log-Lane, SQL-Dienstrestart, dateigenauem Create, synthetischem
  Backup/Restore-Roundtrip, Persistenz nach vollständigem VM-Restart und
  scopegebundenem Cleanup; der Lauf wurde nach Einführung der gebundenen
  Ressourcenroots mit isoliertem Prepared-Image erneut real bestätigt und
  hinterließ weder Test-Artifact, State noch rungebundene VHDX;
- reale allgemeine Hyper-V-Parent-Storage-Migration einer isolierten
  Nicht-Default-Location mit Test-VM und VHDX, journalisierter Vorwärts- und
  Rückmigration, Umbindung von VM-Konfiguration, Snapshots, Smart Paging und
  VHDX sowie vollständiger Wiederherstellung und scopegebundenem Cleanup;
- providerneutraler Softwarekatalog und External-Runtime-Resolver mit
  SQL-/OS-/Provider-Capability-Gates, sicherer Legacy-`post-start`-Grenze und
  geheimnisfreien Software-Intents für Python, R und Java;
- sicherer versionsbewusster Derived-Image-Buildvertrag für die freigegebenen
  Python-, R- und Java-Varianten auf SQL Server 2019, 2022 und 2025 mit
  MCR-Basisdigest, vollständigen DEB-, Wheel-, R-Paket-, JDK-, Java-Extension-
  und OCI-Locks,
  providerneutralem Image-Key, getrennten Docker-/Podman-Receipts,
  rootful-cgroup-v1-Preflight und exakt gebundenem Launch-Capability-Vertrag;
  Docker und Podman bestanden getrennt die katalogisierten echten
  SQL-Datenroundtrips vor und nach providergebundenem Neustart samt
  vollständigem Cleanup; Java besitzt zusätzlich datenbankgebundene,
  idempotente DDL-, Drift- und Fehlerkompensationsverträge; der journalgebundene
  Container-Refresh unterstützt additive Runtimes und eigentumsgebundene
  Java-Removal-Aktionen bei persistierten SQL-/Runtime-Artefaktvolumes;
- Hyper-V-/Windows-External-Runtime-Pfad für Python, R und Java mit
  SHA-256-gebundenen Offlinemedien, geschlossenem PowerShell-Direct-
  Gastinstaller, SQL-Feature-/State-/Recovery-Vertrag sowie echtem
  External-Script-Acceptance-Runner; Python, R und Java bestanden die native
  SQL-2022-Evidence vor und nach vollständigem VM-Kaltstart samt Cleanup;
- schemaabgeleiteter Manifest-Wizard mit Hilfe, schrittweiser Zurücknavigation,
  Zwischenzusammenfassung und sauberem Abbruch ohne partielle Datei sowie
  mutationsfreier External-Runtime- und Sample-/Artifact-Planvorschau;

### Geplant oder unvollständig

- restliche reale erhöhte End-to-End-Abnahme des Hyper-V-Ressourcenroot-
  Schutzes für SQL-Readiness der Legacy-Migration; der erneute N5-
  Mehrgeräte-Nachweis, die Windows-Legacy-Run-/Parent-/Child-Migration sowie
  die allgemeine Parent-Storage-Migration einschließlich VM-Konfiguration,
  Snapshots, Smart Paging, VHDX-Rebind, Rückmigration und Cleanup sind real
  belegt;
- vollständiger allgemeiner Hyper-V-Provider über den belegten
  Windows-2025-/SQL-2025-Referenzpfad hinaus, insbesondere breite
  Datenbank-, Software- und Post-Provisioning-Manifestbindung, positive native
  External-Switch-Erstellung, native Evidence des eng begrenzten Netzwerk-
  Executors, weitergehende Adapter-/Gastnetzreparatur sowie eine reale
  Versions-/Editionsmatrix;
- Hyper-V-SubRuns und ein providerübergreifendes Containernetzwerk innerhalb
  eines Runs;
- vollständige Ausführung aller im Schema vorbereiteten `serverConfig`-Felder;
- nicht freigegebene Archive und Attach-Szenarien;
- reale Runtime-Evidence für automatische Hyper-V-Manifest-Sample-
  Installationen sowie Export und Nutzung von `LAB_GENERATED`-Baselines;
- weitere External-Runtime-OS-/Providerkombinationen außerhalb der belegten
  Linux-Containermatrix und des SQL-2022-Hyper-V-/Windows-Pfads; C# bleibt bis
  zu reproduzierbarem Build und nativer SQL-Evidence `PREVIEW`;
- Reconcile-Aktionen über die implementierten Lifecycle-, Container-,
  Hyper-V-Netzwerk-, vCPU-/RAM-, Grow-only-Storage-, SQL-Storage- und
  SQL-Konfigurations-, SQL-Port- und katalogisierten Testdatenbankpfade hinaus,
  insbesondere Rebinding, Adapter-Neuanlage, Gastadressreparatur, vollständige
  `sp_configure`-Entfernung, freie Mount-/Image-Änderungen und Hyper-V-Software;
- versionierter Refresh-/Rebuild-Lifecycle für Medien, VHDX und Container-Images;
- weitere konsumierende Lab-Packages über die drei abgeschlossenen
  Project-Adapter-Vertical-Slices hinaus;
- langfristige Planner-, Package- und Supporting-Component-Architektur;

Die verbindliche Detailabgrenzung steht in `Documentation/Quality/KNOWN_LIMITATIONS.md`.

## 3. Provider

### Aktuelle Runtimeprovider

```text
Docker
Podman
```

Beide Provider benötigen getrennte Native-Tests. Ein erfolgreicher Docker-Test ist kein Podman-Nachweis und umgekehrt.

Die Nachweise vom 2026-08-27 bis 2026-08-30 bestätigen Docker und Podman
einschließlich CLI-, Batch-, paralleler, gemischter, Restore-, Reconcile- und
External-Runtime-Pfade. Der verbindliche Runtime-Gate des Lab-Core verwendet
SQL Server 2025 als Referenzversion; die allgemeine Windows-/Linux-
Mehrversionsmatrix bleibt bei SQL Analyze und Toolbelt. Die katalogisierten
Linux-External-Runtime-Varianten für SQL Server 2019, 2022 und 2025 besitzen
zusätzlich getrennte native Docker-/Podman-Evidence. Die genaue Abgrenzung
steht in `Documentation/Quality/KNOWN_LIMITATIONS.md` und den dort
referenzierten Validierungsberichten.

Der Provider eines Runs wird in `connection-info.json` gespeichert. Lifecycle und Live-Status müssen diese Bindung verwenden und dürfen nicht zufällig eine andere lokal installierte Runtime auswählen.

### Partieller Runtimeprovider

```text
Hyper-V
```

Hyper-V besitzt neben dem VM-Lifecycle einen positiven
Windows-2025-/SQL-2025-Prepared-Image-Referenzpfad und einen echten
SQL-2025-CLI-Vertical-Slice. Der Ad-hoc-Pfad bietet Hyper-V trotzdem noch nicht
als allgemeinen SQL-Provider an. `New-SqlServerLab -Manifest` verwendet den
eng begrenzten Klonpfad aus einer veröffentlichten
`SQL_PREPARED_SEALED`-Vorlage; die breite Datenbank-, Software-,
Post-Provisioning- und Versionsbindung bleibt offen. Der portable
Network-Intent-Vertrag bindet Container-`nat` sowie Hyper-V-`hostOnly`,
`isolated`, `nat` und `lan`. Hyper-V-NAT besitzt einen mutationsfreien Host-Bound-Plan,
einen gemeinsamen WinNAT-Vertrag, statische scopegebundene IPAM-Leases und einen
gebundenen Gateway-/DNS-Snapshot. Der Lifecycle-Reconcile liest die Hyper-V-
Netzbindung semantisch und hostwertfrei und blockiert bei Drift fail-closed.
LAN verwendet eine lokale Switch-/Adapter-Allowlist, External Switch und
Gast-DHCP; die eng begrenzte schreibende Netzwerkreparatur ist synthetisch
implementiert, positive native Switch-/Repair-Evidence bleibt offen.

Der Hyper-V-Reconcile besitzt getrennte, hostwertfreie Pläne für vCPU/RAM,
zusätzliche VHDX/Grow-only, SQL-Storage, SQL-Konfiguration, den
statischen SQL-TCP-Port und katalogisierte Testdatenbanken. Der SQL-Storage-Slice wird erst nach
einem Host-/Gast-Storage-No-op ausführbar, vergleicht Default- und TempDB-Pfade
read-only und verwendet für Restart, Postconditions und Resume das lokale
Storage-Runtime-Receipt. User-/Systemdatenbankbewegung und positive native
Repair-Evidence bleiben offen. Der Konfigurationsslice vergleicht
persistierte Memory-, MAXDOP-, Cost-Threshold-, `sp_configure`- und Trace-Flag-
Ziele ueber PowerShell Direct. Dynamische Werte und additive Trace Flags werden
live repariert; ein eng begrenztes Zielmanifest darf ausschließlich diesen
Konfigurationsintent ändern. Runtime-Trace-Flags werden nur entfernt, wenn ein
VM-gebundenes Receipt sie als run-eigen nachweist; SQL-Startup- und fremde Flags
bleiben fail-closed. Nicht dynamische Werte werden konfiguriert, mit genau einem
journalisierten `MSSQLSERVER`-Dienstrestart aktiviert und danach zusammen mit
den Trace Flags erneut verifiziert. Ownership und Desired State werden erst
nach den Runtime-Postconditions fortgeschrieben. Die Hyper-V-VM bleibt gestartet.
Ein erhöhter nativer Runner samt isoliertem `SQL_PREPARED_SEALED`-Bootstrap
bindet Plan, `WhatIf`, Live-Änderung, Ownership-Add/-Remove,
Fremd-Trace-Flag-Schutz, ausschließlich `MSSQLSERVER`-Restart, Desired-State-
Rückkehr, No-op und Cleanup ausführbar; seine positive Ausführung ist noch
`NOT_EXECUTED`. Der
Port-Slice bindet genau eine Standardinstanz, Gastfirewall, SQL-Dienstrestart,
Readiness und Connection-State journalisiert. Ein erhöhter nativer Runner samt
isoliertem `SQL_PREPARED_SEALED`-Bootstrap erzeugt eine eng gebundene Gastdrift
und prüft Plan, `WhatIf`, ausschließlich `MSSQLSERVER`-Restart ohne VM-Neustart,
Connection-State, No-op und Cleanup ausführbar; seine positive Ausführung ist
noch `NOT_EXECUTED`. Der Testdatenbank-Slice vergleicht `sys.databases` mit
stabilen Sample-PlanKeys und einem VM-gebundenen lokalen Ownership-Receipt.
Er fuegt katalogisierte Samples ueber den gemeinsamen Handler hinzu und
entfernt nur nachgewiesen run-eigene Outputs nach CHECKSUM-Backup und
`RESTORE VERIFYONLY`; ungebundene Datenbanken bleiben unangetastet. Alte Runs
ohne Ownership-Receipt und breiter Restore-/Create-Reconcile bleiben offen. Ein
erhöhter nativer Runner samt isoliertem `SQL_PREPARED_SEALED`-Bootstrap bindet
Plan, `WhatIf`, Add, No-op, eigentumsgebundene Entfernung, Fremddatenbankschutz,
VM-Restart und Cleanup ausführbar; seine positive Ausführung ist noch
`NOT_EXECUTED`.

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

Data-, Log- und TempDB-Dateipfade sind providerbezogene SQL-Pfade: bei
Containern Linux-Containerpfade, bei Hyper-V ausschließlich die aus Bound Plan
und verifiziertem Runtime-Receipt aufgelösten absoluten Windows-Gastpfade.

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
sichere Script Bundles, mehrere erwartete Outputs und containerbasierte sowie
run-gebundene Hyper-V-`LAB_GENERATED`-Baselines sind ebenfalls implementiert.
Attach-Szenarien und nicht freigegebene Archive bleiben offen. Die automatische
Hyper-V-Manifestbindung für Samples ist synthetisch implementiert; reale
Hyper-V-Sample- und Baseline-Evidence bleibt offen.

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
- Evaluation-OS mit Ablaufzeiten müssen vor Auswahl eines Aufsetzpunkts geprüft werden; ungültige oder ablaufende Baselines werden vorab ausgeschlossen. Automatisierte Windows-Testslots aktivieren nur ihre eindeutige Child-VM nach OOBE über eine temporäre External-NIC und bleiben ohne live bestätigten Status `EVALUATION_ACTIVE` oder `LICENSED` fail-closed.
- Speed bleibt Ziel: Cold-Path (OS_GENERALIZED_SEALED -> Child -> Unattend -> OS_READY) bleibt funktional korrekt und fallback-fähig, Pools/Acceleratoren bleiben optional.
- Nächster KI-Einstiegspunkt: die vorhandene Datei  
  `private_Note/SQL_Server_Lab_HyperV_Workflow_2026-08-08_1108Z_Zero_Touch_Plan.md`, insbesondere Abschnitt 24.

## 17. Operative Einbringung und Hygiene

- Konsistente Wellen werden mit kleinem Scope umgesetzt und **in die aktuelle `main`-Linie gemerged**.
- Nicht mehr benötigte PRs sind zu schließen oder zu löschen, um den Projektzustand zu säubern.
- Commitnachrichten richten sich nach den Projektregeln mit KI-Präfix in der ersten Zeile und klarer Änderungsbeschreibung.
- Branches, deren PRs abgeschlossen sind oder verworfen wurden, sind zeitnah aufzuräumen.
