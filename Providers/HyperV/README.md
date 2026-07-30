# Providers/HyperV/ – Hyper-V-Provider

| Merkmal | Wert |
|---|---|
| Status | `PLANNED` |
| Runtime-Status | `NOT_IMPLEMENTED` |
| Verbindlicher Zielvertrag | [Hyper-V-, Image-, Provisionierungs- und Netzwerkvertrag](../../Documentation/Architecture/HYPERV_IMAGE_PROVISIONING_AND_NETWORK_CONTRACT.md) |
| Artifact-Ergänzung | [Testdatenbank-Provisionierung und Manifest-Wizard](../../Documentation/Architecture/SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md) |

## Zweck

Der Hyper-V-Provider stellt langfristig Windows- und Linux-VMs für
SQL-Server-Labs bereit. Er ist insbesondere für Konstellationen vorgesehen, die
eine vollständige VM, Windows Authentication, native Windows-Dienste,
zusätzliche virtuelle Drives, mehrere NICs, WSFC, Availability Groups oder
plattformgebundene SQL-Features benötigen.

Ein Verzeichnis oder Planungsdokument ist kein Runtime-Nachweis. Aktuell
existieren keine ausführbaren Hyper-V-Providerfunktionen.

## Geplanter Providerumfang

- Capability- und Prerequisite-Prüfung;
- VM-Erstellung aus verifizierten sealed Parent-VHDX;
- Generation 2 und Secure Boot als Default;
- Windows Guest Management über PowerShell Direct;
- Linux Guest Management über cloud-init und SSH;
- Start, Stop, Restart, Status, Remove und scope-sicherer Cleanup;
- zusätzliche VHDX und providerneutrale Drive-Rollen;
- Management- und Lab-Netze;
- resumierbare OS- und SQL-Server-Installation;
- Manual Fallback mit Postcondition-Prüfung;
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
