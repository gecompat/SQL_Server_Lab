# Providers/HyperV/ – Hyper-V-Provider

| Merkmal | Wert |
|---|---|
| Status | `PARTIALLY_IMPLEMENTED` |
| Runtime-Status | `POWERSHELL_DIRECT_SYSPREP_RESUME` |
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
- Status, Start, Stop, Remove und PowerShell Direct;
- VM-Identität über RunId, ScopeId und InstanceId;
- Cleanup-Plan vor der ersten Provider-Mutation;
- eigener synthetischer Native-Smoke-Test ohne Betriebssystem, Netzwerk oder SQL.

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

Der Slice ist kein SQL-Runtime-Nachweis. `New-SqlServerLab` provisioniert noch
keine Hyper-V-Instanz und die Provider-Metadaten setzen `sqlProvisioning` daher
explizit auf `false`.

## Verbleibender Providerumfang

- unattended OS-Build und Rebootsteuerung waehrend der Installation;
- Windows-Specialization nach Verwendung eines sealed Images;
- Linux Guest Management über cloud-init und SSH;
- Restart und Einbindung in die öffentlichen Run-Lifecycle-Cmdlets;
- zusätzliche VHDX und providerneutrale Drive-Rollen;
- Management- und Lab-Netze;
- resumierbare OS- und SQL-Server-Installation;
- echter End-to-End-Sysprep-Nachweis in einem Windows-Gast; der Native-Smoke
  verwendet weiterhin bewusst nur synthetische leere Testmedien;
- SQL Readiness, Software, External Runtimes und Testdatenbanken;
- Diff-/Reconcile-Ablauf für nachträgliche Änderungen.

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

Testdatenbanken bleiben vom OS- und SQL-Image getrennt und verwenden den
gemeinsamen Sample-, Trust-, Verification- und `LAB_GENERATED`-Baseline-
Vertrag.

## Voraussetzungen für den ersten Vertical Slice

- freigegebener Windows-Host mit Hyper-V;
- Runner-Labels `SQL_Lab` und `Hyper-V`;
- verifizierte, rechtlich zulässige OS- und SQL-Medien;
- State und Cleanup Plan vor erster Mutation;
- sequenzielle VM-Builds;
- kein External-Switch-Test ohne ausdrückliche Runner-Freigabe;
- vollständige statische Contract Tests vor Native Smoke Tests.
