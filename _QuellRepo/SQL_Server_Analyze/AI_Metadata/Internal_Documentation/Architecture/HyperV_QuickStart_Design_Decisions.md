# Hyper-V QuickStart: Architektur- und Sicherheitsentscheidungen

**Status:** verbindlich
**Geltungsbereich:** `QuickStart/HyperV/`

## Ziel

Der Hyper-V QuickStart stellt eine eigenständige, lokal isolierte SQL-Server-Testumgebung auf Basis von Hyper-V bereit. Er unterstützt sowohl Windows- als auch Linux-VMs und ermöglicht damit neben der reinen Framework-Nutzung auch die Simulation von Netzwerk-, I/O- und Ressourcenbedingungen, die in Docker-Containern nicht belastbar abbildbar sind.

Der primäre Einstiegspunkt ist:

```powershell
./QuickStart/HyperV/Setup.ps1
```

Für die vollständige Entfernung der verwalteten Umgebung steht bereit:

```powershell
./QuickStart/HyperV/Uninstall.ps1
```

Das Setup kann SQL Server 2019, 2022 und 2025 einzeln oder kombiniert in getrennten VMs bereitstellen und das Framework anschließend automatisch in der synthetischen Datenbank `LabAnalyze` installieren.

## Abgrenzung

### Zum Docker-QuickStart

Docker bietet den schnellsten Einstieg (Pull → Start → fertig). Der Hyper-V QuickStart bietet zusätzlich:

- Echte Netzwerk-Simulation (Bandbreitenlimits, Latenz-Injection auf Hypervisor-Ebene)
- Echte I/O-Drosselung (Storage QoS, IOPS-Limits pro VHDX)
- Native Windows-SQL-Server-Installation (der häufigste Produktionsfall)
- Multi-VM-Szenarien (AG-Simulation, Replikation, Cross-Instanz-Queries)
- CPU- und Memory-Pressure-Simulation (Capping, dynamischer Speicher)
- Vollständige Betriebssystem-Isolation (kein gemeinsamer Kernel)
- Linux-VMs mit SQL Server on Linux + tc/netem für Paket-Level-Simulation

Beide QuickStarts nutzen denselben kanonischen Frameworkinstaller.

### Zum erweiterten Lab

Keine LAB-Run-IDs, Evidence-Gates, Lab-State-Dateien oder Szenariokataloge aus `Lab/`. Gemeinsam genutzt wird ausschließlich der Frameworkinstaller.

Der Hyper-V QuickStart gehört als nutzerorientierte Repro-Umgebung zur Produktlinie.

## Unterstützte VM-Typen

### Windows VM (Native SQL Server)

- **Zweck:** Produktionsnaher Test mit Windows-nativem SQL Server
- **Image-Quelle:** Bereitgestelltes Windows Server VHD/VHDX oder Evaluation-Download
- **SQL-Installation:** Unattended Setup über ConfigurationFile.ini via PowerShell Remoting
- **Authentifizierung:** Mixed Mode (SA + Windows Auth)
- **Vorteil:** Identisches Verhalten wie Produktionsserver (Windows-Dienste, Event Log, Perfmon, Agent)

### Linux VM (SQL Server on Linux)

- **Zweck:** Leichtgewichtigere VM + Netzwerk-/IO-Simulation auf Hypervisor-Ebene
- **Image-Quelle:** Ubuntu Server 22.04/24.04 Cloud-Image (VHDX-Format, kein ISO-Install nötig)
- **SQL-Installation:** Microsoft-Paketrepository + `mssql-conf setup` via SSH
- **Authentifizierung:** Mixed Mode (SA)
- **Vorteil:** Schnelleres Provisioning, geringerer Ressourcenbedarf, tc/netem für Paket-Level-Netzwerksimulation

### Kombinierter Betrieb

Beide VM-Typen können gleichzeitig laufen:

- Windows-Primary + Linux-Secondary (AG-Simulation)
- Mehrere Linux-VMs mit verschiedenen SQL-Versionen und Netzwerk-Constraints
- Eine Windows-VM als Referenz + Linux-VMs unter Last/Drosselung
- Cross-Plattform-Vergleich desselben Frameworks auf Windows vs. Linux

## Base-Image-Strategie

### Option 1: Bereitgestelltes VHD/VHDX (bevorzugt)

Der Benutzer stellt ein vorbereitetes VHDX bereit:

**Windows:**
- Windows Server 2019, 2022 oder 2025 (Core oder Desktop Experience)
- Sysprep-generalisiert (OOBE-Phase beim ersten Start)
- Generation-2-kompatibel (UEFI, GPT-Partitionierung)
- Mindestens 40 GB Basegröße

**Linux:**
- Ubuntu Server 22.04 oder 24.04 Cloud-Image (VHDX)
- Alternativ: Jede von Hyper-V unterstützte Linux-Distribution mit systemd
- Generation-2-kompatibel

### Option 2: Automatischer Download (Fallback)

**Windows:**
- Windows Server 2022 Evaluation ISO von Microsoft (ca. 5 GB)
- Automatische VHD-Erstellung via `Convert-WindowsImage` oder DISM
- 180-Tage-Evaluationslizenz

**Linux:**
- Ubuntu Server Cloud-Image im VHDX-Format (ca. 600 MB)
- Direkter Download, kein ISO-Install nötig
- cloud-init für automatische Erstkonfiguration (User, SSH-Key, Netzwerk)

Downloads werden im lokalen Cache gespeichert. SHA256-Prüfsummen nach Download validiert.

### Differencing Disks

Pro SQL-Server-Version wird ein Differencing Disk vom Base-VHDX erzeugt:

```text
<VmRoot>/
  base/windows-server-base.vhdx         (nur lesen)
  vm-2019/sql2019-diff.vhdx             (Differencing → base)
  vm-2022/sql2022-diff.vhdx             (Differencing → base)
  vm-2025/sql2025-diff.vhdx             (Differencing → base)
```

Vorteil: Schnelle Bereitstellung, minimaler Speicherverbrauch, unabhängige VM-Zustände.

## VM-Architektur

- **Generation:** 2 (UEFI, Secure Boot deaktiviert für Flexibilität)
- **Dynamischer Speicher:** Ja, mit konfigurierbarem Minimum/Maximum
- **Prozessoren:** Konfigurierbar pro Ressourcenprofil
- **Netzwerk:** Interner Switch mit NAT für Internet (während Setup), danach optional isoliert
- **Checkpoints:** Deaktiviert (kein automatisches Checkpointing)
- **Integrationsdienste:** Aktiviert (Guest Services für Dateikopie)

## Netzwerk

Setup erstellt dedizierte Hyper-V Switches:

### Management-Switch (Internal)

- Name: `SQL_Server_Analyze_Mgmt`
- Typ: Internal
- NAT-Netzwerk für Internet-Zugang (SQL Server Setup, Paket-Downloads)
- Statische IP-Adressierung (kein DHCP):
  - Host-Gateway: `172.30.0.1/24`
  - VM SQL 2019 (Windows): `172.30.0.19`
  - VM SQL 2022 (Windows): `172.30.0.22`
  - VM SQL 2025 (Windows): `172.30.0.25`
  - VM SQL 2019 (Linux): `172.30.0.119`
  - VM SQL 2022 (Linux): `172.30.0.122`
  - VM SQL 2025 (Linux): `172.30.0.125`
- SQL-Port: Standard 1433 (in jeder VM)
- Host-Verbindung via IP oder optional `hosts`-Eintrag

### Lab-Switch (Private, optional)

- Name: `SQL_Server_Analyze_Lab`
- Typ: Private (kein Host-Zugang, nur VM ↔ VM)
- Subnetz: `172.30.1.0/24`
- Zweck: Multi-VM-Szenarien (AG, Replikation) und Netzwerk-Isolation
- Nur erstellt, wenn Multi-VM oder Netzwerksimulation gewählt

## Netzwerk-Simulation

Hyper-V ermöglicht auf Adapter-Ebene:

| Simulation | Hyper-V Mechanismus | Docker-Äquivalent |
|---|---|---|
| Bandbreitenlimit | `Set-VMNetworkAdapter -MaximumBandwidth` | Nicht verfügbar |
| Minimum-Bandbreite | `Set-VMNetworkAdapter -MinimumBandwidthAbsolute` | Nicht verfügbar |
| Latenz / Paketloss | tc/netem in Linux-VM (auf Lab-NIC) | Nur in Linux-Container |
| Isolierte Subnetze | Private Switch pro Szenario | Bridge-Netzwerk |
| Multi-Subnet | Mehrere NICs pro VM | Mehrere Networks |

### Netzwerk-Profile

| Profil | Bandbreite | Latenz | Paketloss |
|---|---:|---:|---:|
| Unbegrenzt | ∞ | 0 ms | 0% |
| WAN-Simulation | 100 Mbit/s | 20 ms | 0.1% |
| Langsames Netz | 10 Mbit/s | 50 ms | 1% |
| Benutzerdefiniert | konfigurierbar | konfigurierbar | konfigurierbar |

Latenz und Paketloss werden innerhalb der Linux-VM via `tc qdisc add dev eth1 root netem` gesetzt. Windows-VMs unterstützen nur Bandbreitenlimits auf Hypervisor-Ebene.

## I/O-Simulation

| Simulation | Hyper-V Mechanismus |
|---|---|
| IOPS-Limit | `Set-VMHardDiskDrive -MaximumIOPS` |
| Minimum-IOPS | `Set-VMHardDiskDrive -MinimumIOPS` (Storage QoS) |
| Langsame Disk | Separates VHDX mit IOPS-Cap für Data-Files |
| Schnelle TempDB | Eigenes VHDX ohne Limit |

### I/O-Profile

| Profil | Data IOPS | Log IOPS | TempDB IOPS |
|---|---:|---:|---:|
| Unbegrenzt | ∞ | ∞ | ∞ |
| Gedrosselt | 500 | 1000 | ∞ |
| Asymmetrisch | 200 | 500 | 5000 |
| Benutzerdefiniert | konfigurierbar | konfigurierbar | konfigurierbar |

## Ressourcen-Simulation

| Simulation | Hyper-V Mechanismus |
|---|---|
| Memory Pressure | Dynamischer Speicher mit niedrigem Maximum |
| CPU Throttling | `Set-VMProcessor -Maximum` (Prozent-Cap) |
| CPU Overcommit | Mehr vCPUs als physische Kerne |
| NUMA-Awareness | VM-NUMA-Konfiguration |

## SQL Server Installation

### Windows VM: Unattended Setup

SQL Server wird via `setup.exe /ConfigurationFile=...` installiert:

- **Edition:** Developer (kostenfrei, voller Funktionsumfang)
- **Authentifizierung:** Mixed Mode (SA + Windows Auth)
- **SA-Passwort:** Aus `.env`
- **Features:** SQLENGINE, FULLTEXT, CONN
- **Collation:** `SQL_Latin1_General_CP1_CS_AS`
- **Instanzname:** MSSQLSERVER (Default)
- **Query Store:** Aktiviert nach Installation
- **SQL Agent:** Aktiviert und gestartet
- **TempDB:** Auf eigenem VHDX (wenn I/O-Profile aktiv)
- **Data/Log-Trennung:** Separate VHDX wenn gewählt

### Linux VM: Paket-Installation

1. Microsoft-Paketrepository hinzufügen (via SSH/cloud-init)
2. `mssql-server` + `mssql-tools18` installieren
3. `mssql-conf setup` mit SA-Passwort, Collation und Speicherlimit
4. Optional: `mssql-server-agent` für Agent-Tests
5. Query Store aktivieren
6. tc/netem konfigurieren wenn Netzwerk-Profil gewählt

### SQL Server Media

**Windows:** Lokales ISO oder automatischer Download der Developer Edition. Cache im Speicherpfad.

**Linux:** Automatisch via Paketmanager aus Microsoft-Repository. Kein ISO nötig.

## Speicherlayouts

### Single Root

```text
<LabRoot>/
  base/                          (Base-VHDX, ISO-Cache)
  vm-2019/                       (Differencing Disk, VM-Konfiguration)
  vm-2022/
  vm-2025/
  control/                       (Scope-Marker, Installer-Kopie)
```

### Separate Roots

Für Systeme mit mehreren Datenträgern:

- Control Root: Marker, Installer, Base-Image
- VM Root: VHDs und VM-Konfigurationsdateien

## Ressourcenprofile

| Profil | RAM (Start/Max) | vCPUs | VHD Max |
|---|---:|---:|---:|
| Compact | 4/6 GiB | 2 | 60 GB |
| Standard | 8/12 GiB | 4 | 80 GB |
| Performance | 16/24 GiB | 8 | 120 GB |

Bei mehreren VMs wird die Hostbelastung geprüft und eine Bestätigung verlangt wenn die Summe 70% des Hostspeichers überschreitet.

## Pfadsicherheit

Identisch zum Docker-QuickStart:

- Zielpfade müssen absolut und lokal sein;
- Laufwerks- und Dateisystemwurzeln sind unzulässig;
- Betriebssystem-, Programm- und Repositorypfade sind unzulässig;
- Benutzerprofilwurzel ist unzulässig;
- Netzwerkpfade, Junctions und symbolische Links sind unzulässig;
- getrennte Speicherwurzeln dürfen sich nicht überlappen.

Scope-Marker werden in jeder verwalteten Wurzel angelegt. Start, Stop und Remove akzeptieren nur Pfade mit passendem Marker.

## Lokale Secrets

```text
QuickStart/HyperV/.env
```

Enthält SA-Passwort, VM-Konfiguration, Pfade. Durch `.gitignore` ausgeschlossen. `.env.example` enthält nur synthetische Platzhalter.

## Lifecycle

| Aktion | Wirkung |
|---|---|
| Setup | Konfiguration abfragen, VMs erstellen, OS vorbereiten, SQL installieren, Framework deployen |
| Start | Gespeicherte VMs starten, Netzwerk prüfen, SQL-Verfügbarkeit bestätigen |
| Status | VM-Zustand, SQL-Konnektivität, Framework-Version anzeigen |
| Stop | VMs herunterfahren (Guest Shutdown) |
| Remove | VMs löschen, Differencing Disks entfernen, Base optional behalten |
| Uninstall | Vollständige Entfernung inkl. Base, Switch, NAT, Marker |

## Voraussetzungen auf dem Host

- Windows 10/11 Pro oder Windows Server mit aktivierter Hyper-V-Rolle
- PowerShell 7+
- Administrationsberechtigung (Hyper-V-Cmdlets erfordern Elevation)
- Mindestens 20 GB freier Speicher pro VM (Windows) bzw. 10 GB pro VM (Linux)
- Für Windows-VMs: Windows Server ISO/VHD oder Internetzugang
- Für Linux-VMs: Internetzugang für Cloud-Image und Paket-Download
- Optional: SSH-Client (für Linux-VM-Verwaltung; in Windows 10+ integriert)

## Unterstützte Laufzeitvarianten

- Windows 10/11 Pro mit Hyper-V
- Windows Server 2019/2022/2025 mit Hyper-V-Rolle
- Nested Virtualization in einer Azure/Hyper-V VM (mit ExposeVirtualizationExtensions)

## Nicht im Scope

- Domain-Join oder Active-Directory-Integration
- Cluster-Konfiguration (Failover Clustering)
- Externe Netzwerkfreigabe der VMs über den Host hinaus
- Produktiver Betrieb (nur synthetische Testumgebung)
- Automatische OS-Updates innerhalb der VMs
- Provisionierung des Hyper-V-Hosts selbst (Rolle muss aktiviert sein)

## Frameworkinstallation

Nach SQL-Server-Bereitschaft erzeugt der QuickStart den Standalone-Installer und installiert pro VM:

1. `LabAnalyze` mit `SQL_Latin1_General_CP1_CS_AS` erstellen;
2. Framework installieren oder aktualisieren;
3. Schema `monitor` als `FRAMEWORK_READY` verifizieren.

Das SA-Passwort wird dabei ausschließlich via SecureString/Credential übergeben.
