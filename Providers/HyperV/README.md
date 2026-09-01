# Providers/HyperV/ – Hyper-V-Provider

| Merkmal | Wert |
|---|---|
| Status | `PARTIALLY_IMPLEMENTED` |
| Runtime-Status | `WINDOWS_SPECIALIZATION_SQL_READINESS_ORCHESTRATION` |
| Verbindlicher Zielvertrag | [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](../../Documentation/Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md) |
| Artifact-Ergänzung | [Testdatenbank-Provisionierung und Manifest-Wizard](../../Documentation/Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md) |

## Zweck

Der Hyper-V-Provider stellt langfristig Windows- und Linux-VMs für
SQL-Server-Labs bereit. Er ist insbesondere für Konstellationen vorgesehen, die
eine vollständige VM, Windows Authentication, native Windows-Dienste,
zusätzliche virtuelle Drives, mehrere NICs, WSFC, Availability Groups oder
plattformgebundene SQL-Features benötigen.

`HyperVProvider.ps1` implementiert die erste ausführbare Lifecycle-Grundlage:

- read-only Parent-VHDX mit expliziter SHA-256-Prüfung;
- Differencing Child innerhalb des Run-Verzeichnisses;
- Generation 2 und Secure Boot mit Windows-Template;
- bis zu 16 run-lokale dynamische oder feste Zusatz-VHDX mit Rollen
  `sqlData`, `sqlLog`, `tempdb`, `backup` oder `general` und SCSI-Anbindung;
- stabile Host-/Gast-Zuordnung über den VHDX-DiskIdentifier sowie idempotente
  GPT-/NTFS-Initialisierung mit expliziter Allocation Unit, Volume Label und
  Gastpfad über PowerShell Direct;
- Windows-Specialization mit validiertem Computernamen, vor dem Gastneustart
  persistiertem `REBOOT_REQUIRED` und begrenztem PowerShell-Direct-Reconnect;
- Windows-Testslot-Lizenz-Gate mit Online-Evaluationsaktivierung, positiver
  Restlaufzeit und einer garantiert wieder entfernten zweiten NIC an einem
  optional vorgegebenen oder automatisch aufgelösten External-Switch; bereits
  aktivierte, wiederverwendete Slots benötigen diesen Netzwerkpfad nicht;
- SQL-Readiness im Gast mit SQL-Dienst-, Major-Version- und Online-Prüfung der
  vier Systemdatenbanken; nur sanitierte `SQL_READY_RUN`-Evidenz wird in den
  VM-Notizen gespeichert;
- Status, Start, Stop, Remove und PowerShell Direct;
- deklarativer VM-Autostart (`instances[].autostart: on|off`) über Hyper-Vs
  `AutomaticStartAction`, standardmäßig ausgeschaltet;
- VM-Identität über RunId, ScopeId und InstanceId;
- portables `hostOnly`-/`isolated`-/`nat`-/`lan`-Binding mit lokaler
  Switch-/Adapterbindung, NAT-IPAM beziehungsweise LAN-DHCP;
- hostwertfreier Netzwerk-Reconcile-Plan und journalisierte Reparatur nur für
  additive gebundene Infrastruktur und genau einen vorhandenen getrennten
  Adapter; External-Switch-Erstellung benötigt eine zusätzliche Freigabe;
- manifestgebundener vCPU-/RAM-Reconcile mit statischem oder dynamischem RAM,
  Min/Startup/Max, Live-Min-/Max-Anpassung und journalisiertem Stop-Apply-Start;
- manifestgebundener Add-/Grow-only-Storage- und SQL-Dateiplatzierungs-Reconcile
  sowie SQL-Konfigurations-Reconcile fuer Memory, MAXDOP, Cost Threshold,
  explizite `sp_configure`-Werte und globale Trace Flags; dynamische Werte und
  eigentumsgebundene Runtime-Add-/Remove-Aktionen bleiben live, Startup- und
  fremde Flags fail-closed, nicht dynamische Werte verwenden nur einen
  kontrollierten `MSSQLSERVER`-Dienstrestart ohne VM-Neustart;
- manifestgebundener SQL-TCP-Port-Reconcile für genau eine Standardinstanz mit
  gebundener Gastfirewall, kontrolliertem SQL-Dienstrestart und ohne VM-Neustart;
- Cleanup-Plan vor der ersten Provider-Mutation;
- eigener synthetischer Native-Smoke-Test ohne Betriebssystem, Netzwerk oder SQL.

Der erhöhte SQL-Konfigurations-Akzeptanzrunner und sein isolierter
`SQL_PREPARED_SEALED`-Bootstrap prüfen Plan, `WhatIf`, Live-Änderung,
Ownership-Add/-Remove, Fremd-Trace-Flag-Schutz, ausschließlich
`MSSQLSERVER`-Restart ohne VM-Neustart, Desired-State-Rückkehr, No-op und
scopegebundenen Cleanup. Der Runner ist ausführbar, wurde aber noch nicht nativ
ausgeführt (`NOT_EXECUTED`).

Der getrennte erhöhte SQL-Port-Akzeptanzrunner erzeugt in einem neuen
Prepared-Image-Klon eine kontrollierte TCP-/Firewall-Drift und prüft den
öffentlichen Plan, `WhatIf`, ausschließlich `MSSQLSERVER`-Restart ohne
VM-Neustart, Connection-State, No-op sowie scopegebundenen Cleanup. Sein
Prepared-Artifact-Bootstrap ist ebenfalls isoliert; der native Lauf ist noch
`NOT_EXECUTED`.

`Private/HyperVImageRegistry.ps1` ergänzt eine immutable, inhaltsadressierte
Registry für operatorseitig bereitgestellte `OS_SEALED`- und
`SQL_PREPARED_SEALED`-VHDX. Der Import prüft read-only, VHDX-Signatur,
SHA-256, Generalisierungs- beziehungsweise SQL-Prepare-Evidence und persistiert
keine Hostpfade im Manifest Lock. Der Resolver schließt ablaufende Evaluationen
und synthetische Test-Artefakte aus und begründet verworfene Kandidaten.

`Private/HyperVImageBuilder.ps1` plant einen Build aus einem lokal
SHA-256- und ISO-9660-verifizierten Windows-Medium, persistiert Resume-State und
erzeugt einen isolierten Generation-2-Builder mit Secure Boot, OS-VHDX und
DVD-Boot. Die OS-Installation endet zunächst bewusst in
`MANUAL_ACTION_REQUIRED`. Nach der manuellen OS-Installation kann die Runtime
Sysprep ueber PowerShell Direct ausfuehren, den Microsoft-ImageState pruefen,
den Gast-Shutdown beobachten und die an BuildId, ScopeId und Challenge
gebundene Evidenz automatisch erzeugen. Der Zwischenzustand `REBOOT_REQUIRED`
ist ohne erneute Credential-Eingabe resumierbar; Gast-Credentials werden nicht
persistiert. Vor der Publikation prüft die Runtime außerdem VM-Identität,
fehlende Checkpoints und die VHDX-Pfadgrenze. Reale Medien werden erst danach
als immutable `OS_SEALED` registriert; synthetische CI-Medien bleiben zwingend
`LIFECYCLE_TEST_ONLY` und duerfen den Sysprep-Pfad nicht ausfuehren.

Der Slice ist kein allgemeiner SQL-Runtime-Nachweis. `New-SqlServerLab` kann
einen eng begrenzten `SQL_PREPARED_SEALED`-Manifest-Klon mit OOBE-,
`CompleteImage`- und Readiness-Orchestrierung erstellen; die Provider-Metadaten
kennzeichnen dies separat als `prepared-image-clone-only`. Allgemeines
Manifest-Binding und echter Windows-/SQL-End-to-End-Nachweis bleiben offen.

Entsprechend erscheint Hyper-V noch nicht als allgemeiner ausführbarer Provider
im `Invoke-SqlServerLab`-Menü. Eine breite Freigabe folgt erst nach allgemeinem
Manifest-Binding, Netzwerkzugriff und echtem Windows-/SQL-End-to-End-Test.

## Verbleibender Providerumfang

- unattended OS-Build und Rebootsteuerung waehrend der Installation;
- Linux Guest Management über cloud-init und SSH;
- Restart und Einbindung in die öffentlichen Run-Lifecycle-Cmdlets;
- echter End-to-End-Nachweis der Initialisierung in einem Windows-Gast;
- Bindung des bestehenden providerneutralen Manifest-Drive-Vertrags;
- weitergehende Management-/Lab-Netze, Adapter-Neuanlage, Rebinding und
  Gastadressreparatur;
- resumierbare OS- und SQL-Server-Installation;
- echter End-to-End-Sysprep-Nachweis in einem Windows-Gast; der Native-Smoke
  verwendet weiterhin bewusst nur synthetische leere Testmedien;
- breitere Software-, Post-Provisioning- und allgemeine Datenbankbindung;
- Reconcile für direkte Create-/Restore-Datenbanken, Storage-Rebinding/-Removal,
  vollständige `sp_configure`-Entfernung sowie weitere noch nicht klassifizierte
  SQL-Konfiguration;
- positive native Evidence fuer den katalogisierten Testdatenbank-Reconcile.

## Verbindliche Aufsetzpunkte

1. `MEDIA_VERIFIED`;
2. `OS_SEALED`;
3. `SQL_PREPARED_SEALED`;
4. run-lokal `SQL_READY_RUN`;
5. run-lokal `EXTENSIONS_READY_RUN`;
6. optional run-lokal `DATABASES_READY_RUN`.

Globale Baselines müssen generalisiert, immutable, SHA-256-verifiziert und
vollständig auf ihre Quellen zurückführbar sein. Checkpoints sind run-lokale
Recovery Points und keine allgemeinen Golden Images.

## Software, External Runtimes und Datenbanken

Software ist nicht auf Hyper-V beschränkt. Python, R, Java und andere Pakete
werden über einen providerneutralen Capability- und Artifact-Vertrag für
Hyper-V, Docker und Podman geplant. Für Container sind versionierte Derived
Images der reproduzierbare Default.

Für SQL Server 2022 auf Windows existiert ein geschlossener Hyper-V-Gastpfad
für Python, R und Java: Offlinemedien werden im Media Root per SHA-256
verifiziert, nur ein quellfreier Plan wird in den Gast kopiert, und
Installation, ACLs, Runtime-Registrierung, State/Recovery sowie echte
External-Script-Postconditions sind orchestriert. Python, R und Java bestanden
die native SQL-2022-Acceptance vor und nach vollständigem VM-Kaltstart sowie den
scopegebundenen Cleanup; die drei Windows-Varianten sind `SUPPORTED`.

Testdatenbanken bleiben vom OS- und SQL-Image getrennt und verwenden den
gemeinsamen Sample-, Trust-, Verification- und `LAB_GENERATED`-Baseline-
Vertrag. Neue Manifest-Runs persistieren fuer erfolgreich installierte Samples
ein VM-gebundenes lokales Ownership-Receipt. Der getrennte Reconcile kann
katalogisierte Samples addieren und nur diese nach CHECKSUM-Backup plus
`RESTORE VERIFYONLY` entfernen; ungebundene Datenbanken bleiben fail-closed.

## Voraussetzungen für den ersten Vertical Slice

- freigegebener Windows-Host mit Hyper-V;
- Runner-Labels `SQL_Lab` und `Hyper-V`;
- verifizierte, rechtlich zulässige OS- und SQL-Medien;
- State und Cleanup Plan vor erster Mutation;
- sequenzielle VM-Builds;
- kein External-Switch-Test ohne ausdrückliche Runner-Freigabe;
- kein realer Aktivierungstest ohne ausdrücklich freigegebene verbundene
  physische NIC;
- vollständige statische Contract Tests vor Native Smoke Tests.
