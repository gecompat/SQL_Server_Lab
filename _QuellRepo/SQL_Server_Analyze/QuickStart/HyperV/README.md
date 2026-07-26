# Hyper-V QuickStart

Dieser Bereich stellt eine eigenstaendige Hyper-V-Testumgebung fuer
`SQL_Server_Analyze` bereit. Er unterstuetzt sowohl Windows- als auch Linux-VMs
und ermoeglicht neben der Framework-Nutzung auch die Simulation von Netzwerk-,
I/O- und Ressourcenbedingungen auf Hypervisor-Ebene.

Der QuickStart ist vom Docker-QuickStart und vom erweiterten Lab getrennt:

- keine Docker- oder Container-Abhaengigkeit;
- Windows-VMs: native Windows Authentication und vollstaendiger Agent;
- Linux-VMs: Netzwerk-/I/O-Simulation (Latenz, Bandbreite, IOPS);
- keine LAB-Run-IDs oder Evidence-Gates;
- nur der kanonische Frameworkinstaller unter `Code/Install` wird wiederverwendet.

## Betriebsmodi

| Modus | Betriebssystem | SQL Server | Besonderheit |
|---|---|---|---|
| Windows | Windows Server 2019/2022/2025 | Nativ installiert | Windows Auth, voller Agent |
| Linux | Ubuntu Server 24.04 | APT-Paket | Netzwerk-/I/O-Simulation |
| Gemischt | Beide im selben Netzwerk | Cross-Platform | AG-Szenarien, Linked Server |

## Voraussetzungen

- Windows 10/11 Pro oder Windows Server mit aktivierter Hyper-V-Rolle;
- PowerShell 7+ (als Administrator);
- mindestens 20 GB freier Speicher pro Windows-VM, 15 GB pro Linux-VM;
- Windows-Modus: generalisiertes (sysprep) Windows Server VHDX oder Internetzugang;
- Linux-Modus: Ubuntu Cloud Image VHDX wird automatisch heruntergeladen (~600 MB);
- Windows ADK (fuer cloud-init ISO-Erstellung bei Linux-VMs).

## Ein Einstiegspunkt

PowerShell 7 als Administrator im Repository-Root oeffnen und ausfuehren:

```powershell
./QuickStart/HyperV/Setup.ps1
```

`Setup.ps1` fuehrt beim ersten Aufruf durch die Einrichtung. Bei spaeteren
Aufrufen zeigt es ein Menue fuer Start, Status, Stop und Remove.

Direkte Aktionen:

```powershell
./QuickStart/HyperV/Setup.ps1 -Action Start
./QuickStart/HyperV/Setup.ps1 -Action Status
./QuickStart/HyperV/Setup.ps1 -Action Stop
./QuickStart/HyperV/Setup.ps1 -Action Remove
```

Fuer die vollstaendige Deinstallation:

```powershell
./QuickStart/HyperV/Uninstall.ps1
```

## Was Setup abfragt

Das Setup fragt interaktiv nach:

- **Betriebsmodus:** Windows, Linux oder gemischt;
- SQL-Server-Versionen: 2019, 2022 und/oder 2025;
- Ressourcenprofil: Compact, Standard oder Performance;
- Speicherpfad fuer VMs und VHDs;
- Base-Image-Quelle: lokales VHDX oder automatischer Download;
- Windows: SQL-Server-ISO oder Developer-Edition-Download;
- Linux: Netzwerkprofil und I/O-Profil (aenderbar zur Laufzeit);
- SA-Passwort fuer die synthetischen Testinstanzen;
- automatische Frameworkinstallation in `LabAnalyze`.

## Architektur

```text
<LabRoot>/
  base/
    windows-server-base.vhdx       (generalisiertes Windows-Image, ReadOnly)
    ubuntu-cloud-base.vhdx         (Ubuntu Cloud Image, ReadOnly)
  vm-win-2022/sql2022-diff.vhdx   (Windows Differencing Disk)
  vm-linux-2022/
    sql2022-diff.vhdx              (Linux Differencing Disk)
    data.vhdx                      (Dedizierte Data-Disk fuer I/O-Sim)
    log.vhdx                       (Dedizierte Log-Disk fuer I/O-Sim)
    cloud-init.iso                 (Automatische VM-Konfiguration)
  control/                          (Scope-Marker, Installer-Kopie)
```

Jede SQL-Server-Version erhaelt eine eigene VM mit Differencing Disk. Das
Base-Image wird dabei nicht veraendert. Linux-VMs erhalten zusaetzlich
dedizierte Data- und Log-Disks fuer I/O-Simulation.

## Netzwerk

| VM | IP-Adresse | Port |
|---|---|---:|
| Windows SQL 2019 | 172.30.0.19 | 1433 |
| Windows SQL 2022 | 172.30.0.22 | 1433 |
| Windows SQL 2025 | 172.30.0.25 | 1433 |
| Linux SQL 2019 | 172.30.0.119 | 1433 |
| Linux SQL 2022 | 172.30.0.122 | 1433 |
| Linux SQL 2025 | 172.30.0.125 | 1433 |

Verbindung via SSMS/ADS/sqlcmd:

```text
Server: 172.30.0.22,1433   (Windows)
Server: 172.30.0.122,1433  (Linux)
Login: sa
Passwort: <bei Setup gewaehlt>
```

## Netzwerk- und I/O-Simulation (Linux-VMs)

Linux-VMs unterstuetzen Echtzeit-Simulation von Netzwerk- und
Speicherbedingungen. Profile koennen **zur Laufzeit** geaendert werden —
kein VM-Neustart noetig.

### Netzwerkprofile (tc/netem)

| Profil | Latenz | Bandbreite | Verlust | Einsatz |
|---|---:|---:|---:|---|
| LAN | 0 ms | unbegrenzt | 0% | Lokale Entwicklung |
| WAN | 15 ms +-3 ms | 100 Mbit/s | 0.1% | Remote-Standort |
| Schlecht | 80 ms +-20 ms | 10 Mbit/s | 2% | Stresstest |
| AG | 2 ms +-0.5 ms | 1 Gbit/s | 0% | AG-Synchronisation |

### I/O-Profile (cgroups v2)

| Profil | Read IOPS | Write IOPS | Read MB/s | Write MB/s | Einsatz |
|---|---:|---:|---:|---:|---|
| SSD | unbegrenzt | unbegrenzt | unbegrenzt | unbegrenzt | Normal |
| HDD | 150 | 100 | 120 | 80 | Contention |
| Stressed | 50 | 30 | 40 | 20 | Extremer Druck |
| LogBottleneck | unbegrenzt | 40 | unbegrenzt | 30 | Log-Engpass |

## Ressourcenprofile

| Profil | RAM (Start/Max) | vCPUs | VHD Max |
|---|---:|---:|---:|
| Compact | 4/6 GiB | 2 | 60 GB |
| Standard | 8/12 GiB | 4 | 80 GB |
| Performance | 16/24 GiB | 8 | 120 GB |

## Schutz vor Ueberschreiben

Identisch zum Docker-QuickStart:

- Pfade muessen absolut, lokal und leer sein;
- Betriebssystem-, Programm- und Repositorypfade sind gesperrt;
- Scope-Marker schuetzen vor versehentlicher Mutation fremder Daten;
- Remove und Uninstall erfordern Bestaetigung und Marker-Pruefung.

## Lokale `.env`

Die erzeugte `.env` enthaelt das SA-Passwort und VM-Konfiguration. Die Datei ist
durch die Repository-`.gitignore` ausgeschlossen. `.env.example` enthaelt nur
synthetische Platzhalter.

## Unterschiede zum Docker-QuickStart

| Aspekt | Docker | Hyper-V |
|---|---|---|
| Plattform | Linux-Container | Windows- und/oder Linux-VMs |
| Auth | SA only | SA + Windows (Windows-VMs) |
| Agent | begrenzt | vollstaendig |
| Netzwerksimulation | nicht moeglich | tc/netem (Linux-VMs) |
| I/O-Simulation | nicht zuverlaessig | cgroups + dedizierte VHDs |
| Multi-NIC | nicht moeglich | beliebig viele NICs |
| Startzeit | Sekunden | 30-60 Sekunden |
| Speicher | GB (Container) | 15-20+ GB (VHD) |
| Isolation | Container-Limits | Vollstaendige VM-Isolation |
