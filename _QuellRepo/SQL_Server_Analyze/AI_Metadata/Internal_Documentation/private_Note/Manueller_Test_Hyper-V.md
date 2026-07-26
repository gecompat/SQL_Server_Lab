## Manueller Test: Hyper-V QuickStart

### Voraussetzungen prüfen

**Auf dem Windows-System (Key18):**

1. PowerShell 7 als Administrator öffnen
2. Prüfen:

```powershell
# Hyper-V aktiv?
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V | Select State

# PowerShell-Version?
$PSVersionTable.PSVersion

# Freier RAM?
[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
```

Falls Hyper-V nicht aktiv: `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All` (Neustart nötig).

---

### Test-Durchlauf

**Schritt 1:** Repository aktuell ziehen

```powershell
cd <Pfad-zum-Repo>\SQL_Server_Analyze
git pull origin main
```

**Schritt 2:** Setup starten

```powershell
./QuickStart/HyperV/Setup.ps1
```

**Schritt 3:** Bei den interaktiven Fragen empfehle ich für den ersten Test:

| Frage | Antwort |
| --- | --- |
| Betriebsmodus | **2** (Linux) — schnellster Test, kleinstes Image |
| SQL-Version | nur **2022** (eine reicht) |
| Ressourcenprofil | **1** (Compact — 4 GB RAM) |
| Speicherpfad | Standard akzeptieren oder z.B. `D:\Lab\HyperV` |
| Linux Base-Image | **2** (Auto-Download, ~600 MB) |
| Netzwerkprofil | **1** (LAN — keine Simulation initial) |
| I/O-Profil | **1** (SSD — keine Drosselung initial) |
| SA-Passwort | z.B. `Test#Lab2026!` |
| Framework installieren | **Ja** |
| Jetzt erstellen? | **Ja** |

---

### Was dabei passieren sollte (Erwartung)

1. SSH-Key wird generiert (`.ssh/lab_ed25519`)
2. Interner Switch + NAT wird erstellt
3. Ubuntu Cloud-Image wird heruntergeladen (~600 MB)
4. cloud-init ISO wird erzeugt (**hier braucht es `oscdimg.exe` aus Windows ADK!**)
5. VM wird erstellt (Gen2, Differencing Disk + Data + Log)
6. VM startet, cloud-init konfiguriert User + Netzwerk
7. SSH-Verbindung wird aufgebaut
8. SQL Server wird via APT installiert
9. Framework wird deployed
10. Status-Ausgabe mit IP

---

### Wahrscheinliche Stolpersteine

| Problem | Lösung |
| --- | --- |
| `oscdimg.exe nicht gefunden` | Windows ADK installieren oder ich baue eine PowerShell-Alternative |
| `Nested Virtualization` Fehler | Runner ist selbst eine VM → `Set-VMProcessor -ExposeVirtualizationExtensions $true` auf dem Host |
| Download-Timeout | Netzwerk/Proxy auf Key18 prüfen |
| SSH-Verbindung schlägt fehl | Firewall-Regel für Port 22 auf dem internen Switch |

---

### Ergebnis melden

Wenn es durchläuft oder abbricht — den **letzten Output** (Fehler oder Erfolg) hier reinkopieren. Dann kann ich gezielt fixen.

**Tipp:** Falls Sie zuerst nur die **Module-Ladephase** testen wollen (ohne tatsächlich VMs zu erstellen), können Sie mit Ctrl+C nach der Konfigurationsphase abbrechen — dann sehen Sie ob alle `.ps1`-Dateien fehlerfrei laden.

---

## Windows Base-VHDX erstellen

Der QuickStart benötigt ein generalisiertes (sysprep) Windows Server VHDX als
Basis für die Differencing Disks. Einmal erstellt, wird es für alle VMs
wiederverwendet.

### Option A: Aus vorhandener Windows Server ISO (empfohlen)

**Voraussetzung:** Windows Server 2022 ISO (Evaluation oder MSDN).
Download: https://www.microsoft.com/de-de/evalcenter/evaluate-windows-server-2022

```powershell
# 1. Hyper-V Manager → Neue VM erstellen (temporär)
$tempVmName = 'BaseImage_Build'
$vhdxPath = 'C:\Lab\Base\windows-server-base.vhdx'

# Verzeichnis erstellen
New-Item -Path 'C:\Lab\Base' -ItemType Directory -Force

# Neues VHDX (60 GB, dynamisch)
New-VHD -Path $vhdxPath -SizeBytes 60GB -Dynamic

# Temporäre VM für die Installation
New-VM -Name $tempVmName -Generation 2 -MemoryStartupBytes 4GB -VHDPath $vhdxPath
Set-VMProcessor -VMName $tempVmName -Count 4
Set-VMFirmware -VMName $tempVmName -EnableSecureBoot On

# ISO einlegen
Add-VMDvdDrive -VMName $tempVmName -Path 'D:\ISOs\windows_server_2022.iso'
$dvd = Get-VMDvdDrive -VMName $tempVmName
Set-VMFirmware -VMName $tempVmName -FirstBootDevice $dvd

# VM starten und Windows installieren
Start-VM -Name $tempVmName
```

**Manuelle Schritte in der VM (vmconnect):**

1. Windows Server 2022 Standard (Desktop Experience) installieren
2. Administrator-Passwort setzen (z.B. `P@ssw0rd`)
3. Windows Update laufen lassen (optional, vergrößert aber das Image)
4. **Sysprep ausführen:**

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

5. Warten bis die VM sich herunterfährt (nach Sysprep)

**Nach dem Shutdown:**

```powershell
# Temporäre VM entfernen (VHDX behalten!)
Remove-VM -Name 'BaseImage_Build' -Force

# VHDX komprimieren (optional, spart Platz)
Optimize-VHD -Path 'C:\Lab\Base\windows-server-base.vhdx' -Mode Full

# Ergebnis prüfen
Get-VHD -Path 'C:\Lab\Base\windows-server-base.vhdx' | Select Path, VhdFormat, VhdType, FileSize, Size
```

Das resultierende VHDX ist ca. 8–12 GB groß und kann beim QuickStart-Setup
als "Lokales VHDX bereitstellen" angegeben werden.

### Option B: Convert-WindowsImage (schneller, ohne manuelle Installation)

**Voraussetzung:** Windows ADK oder das PowerShell-Modul `Convert-WindowsImage`.

```powershell
# Modul laden (von https://github.com/x0nn/Convert-WindowsImage)
Install-Module -Name Convert-WindowsImage -Scope CurrentUser

# ISO → VHDX (unattended, bereits generalisiert)
$isoPath = 'D:\ISOs\windows_server_2022.iso'
$vhdxPath = 'C:\Lab\Base\windows-server-base.vhdx'

Convert-WindowsImage -SourcePath $isoPath `
    -VHDPath $vhdxPath `
    -VHDFormat VHDX `
    -SizeBytes 60GB `
    -Edition 'Windows Server 2022 Standard (Desktop Experience)' `
    -DiskLayout UEFI
```

**Hinweis:** Das Ergebnis ist automatisch generalisiert (OOBE beim ersten Start).

### Option C: Bestehendes VHDX wiederverwenden

Falls Sie bereits ein generalisiertes Windows Server VHDX haben (z.B. von
einer früheren Lab-Umgebung), können Sie es direkt angeben. Anforderungen:

- Windows Server 2019, 2022 oder 2025
- Generation-2-kompatibel (UEFI/GPT)
- Sysprep-generalisiert (OOBE-Phase beim ersten Start)
- Mindestens 40 GB VHD-Größe

### Im QuickStart verwenden

Beim Setup die Option **1** (Lokales VHDX bereitstellen) wählen und den
Pfad angeben:

```text
=== Base-Image ===
[1] Lokales VHDX bereitstellen
[2] Evaluation herunterladen (5+ GB)
Windows Server Base-Image [Standard: 1]: 1
Pfad zum Base-VHDX (sysprep-generalisiert, Gen2): C:\Lab\Base\windows-server-base.vhdx
```

Das VHDX wird einmalig in den Lab-Root kopiert und ReadOnly gesetzt.
Alle VMs verwenden Differencing Disks davon.