# QuickStart

Für eine lokal isolierte Docker-Testumgebung wird die Einrichtung über folgenden
Einstiegspunkt gestartet:

```powershell
./QuickStart/Docker/Setup.ps1
```

Eine bestehende QuickStart-Umgebung wird über denselben Menüpfad oder über den
expliziten Deinstallationsaufruf entfernt:

```powershell
./QuickStart/Docker/Uninstall.ps1
```

Die vollständige Anleitung steht unter
[`Docker/README.md`](./Docker/README.md).

Für eine native SQL-Server-Testumgebung via Hyper-V (Windows- und/oder Linux-VMs
mit Netzwerk-/I/O-Simulation):

```powershell
./QuickStart/HyperV/Setup.ps1
```

Deinstallation der Hyper-V-Umgebung:

```powershell
./QuickStart/HyperV/Uninstall.ps1
```

Die vollständige Anleitung steht unter
[`HyperV/README.md`](./HyperV/README.md).

Beide QuickStarts sind vom erweiterten Diagnose-Lab unter `Lab/` getrennt und
verwenden keine LAB-Konfigurationen, Evidence-Gates oder Laufzeitpfade.
