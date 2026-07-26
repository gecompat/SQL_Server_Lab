# Base-Image-Quellen und Download-Referenzen

Diese Datei dokumentiert die externen Quellen, die der Hyper-V QuickStart für die Erstellung der Testumgebung benötigt. Die URLs sind im Code referenziert; diese Übersicht dient der Nachvollziehbarkeit und Reproduzierbarkeit.

## Windows Server Base-VHDX

Der QuickStart verwendet ein generalisiertes (Sysprep) Windows Server VHDX als Basis für Differencing Disks. Jede Windows-VM erzeugt nur eine Differencing Disk; das Base-Image wird als ReadOnly-Parent verwendet und nicht verändert.

### Anforderungen an das Base-Image

- Windows Server 2019, 2022 oder 2025
- Generation 2 (UEFI/GPT-Partitionierung)
- Sysprep-generalisiert (OOBE-Phase beim ersten Start)
- Dynamisches VHDX, mindestens 40 GB logische Größe
- Dateigröße nach Sysprep und Komprimierung: 8–12 GB

### Bezugsquelle: Microsoft Evaluation Center

| Edition | URL | Gültigkeit |
| --- | --- | --- |
| Windows Server 2022 Evaluation | https://www.microsoft.com/de-de/evalcenter/evaluate-windows-server-2022 | 180 Tage |
| Windows Server 2025 Evaluation | https://www.microsoft.com/de-de/evalcenter/evaluate-windows-server-2025 | 180 Tage |

Die Evaluation-ISOs sind ca. 5 GB groß. Nach dem Download wird das ISO in ein generalisiertes VHDX konvertiert (siehe Abschnitt „Erstellung").

### Erstellung des Base-VHDX

#### Variante 1: DISM (Bordmittel, keine Zusatzmodule)

Diese Methode verwendet ausschließlich in Windows integrierte Werkzeuge.

```powershell
# ISO mounten
$iso = Mount-DiskImage -ImagePath 'D:\ISOs\windows_server_2022.iso' -PassThru
$driveLetter = ($iso | Get-Volume).DriveLetter

# Verfuegbare Editionen anzeigen (Index notieren)
Get-WindowsImage -ImagePath "${driveLetter}:\sources\install.wim"
# Index 2 = Standard (Desktop Experience) bei Eval-ISO

# Leeres VHDX erstellen und mounten
$vhdxPath = 'C:\Lab\Base\windows-server-base.vhdx'
New-Item -Path 'C:\Lab\Base' -ItemType Directory -Force
New-VHD -Path $vhdxPath -SizeBytes 60GB -Dynamic
Mount-VHD -Path $vhdxPath

# Disk initialisieren (GPT fuer Gen2)
$disk = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Offline' } | Select-Object -First 1
$disk | Set-Disk -IsOffline $false
$disk | Initialize-Disk -PartitionStyle GPT

# EFI-Partition (100 MB, FAT32)
$efi = $disk | New-Partition -Size 100MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'EFI' -Confirm:$false

# Windows-Partition (restlicher Platz, NTFS)
$win = $disk | New-Partition -UseMaximumSize -AssignDriveLetter
$win | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false
$winLetter = $win.DriveLetter

# Windows-Image anwenden
Expand-WindowsImage -ImagePath "${driveLetter}:\sources\install.wim" -Index 2 -ApplyPath "${winLetter}:\"

# UEFI-Bootloader schreiben
& "${winLetter}:\Windows\System32\bcdboot.exe" "${winLetter}:\Windows" /s "$($efi.AccessPaths[0])" /f UEFI

# Aufraeumen
Dismount-VHD -Path $vhdxPath
Dismount-DiskImage -ImagePath 'D:\ISOs\windows_server_2022.iso'
```

Das resultierende VHDX bootet in die OOBE-Phase. Beim ersten Start muss ein Administrator-Passwort gesetzt werden. Anschließend Sysprep ausführen:

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

Nach dem automatischen Shutdown ist das VHDX generalisiert und einsatzbereit.

#### Variante 2: Temporäre VM mit manueller Installation

```powershell
$vhdxPath = 'C:\Lab\Base\windows-server-base.vhdx'
New-Item -Path 'C:\Lab\Base' -ItemType Directory -Force
New-VHD -Path $vhdxPath -SizeBytes 60GB -Dynamic
New-VM -Name 'BaseImage_Build' -Generation 2 -MemoryStartupBytes 4GB -VHDPath $vhdxPath
Set-VMProcessor -VMName 'BaseImage_Build' -Count 4
Add-VMDvdDrive -VMName 'BaseImage_Build' -Path 'D:\ISOs\windows_server_2022.iso'
$dvd = Get-VMDvdDrive -VMName 'BaseImage_Build'
Set-VMFirmware -VMName 'BaseImage_Build' -FirstBootDevice $dvd
Start-VM -Name 'BaseImage_Build'
```

Manuelle Schritte (vmconnect):

1. Windows Server Standard (Desktop Experience) installieren
2. Administrator-Passwort setzen
3. Optional: Windows Update ausführen (vergrößert das Image)
4. Sysprep ausführen: `sysprep.exe /generalize /oobe /shutdown`
5. Nach Shutdown: VM entfernen, VHDX behalten

```powershell
Remove-VM -Name 'BaseImage_Build' -Force
Optimize-VHD -Path $vhdxPath -Mode Full
```

#### Variante 3: Convert-WindowsImage (PowerShell-Skript)

Das Skript `Convert-WindowsImage` (Quelle: https://github.com/x0nn/Convert-WindowsImage) automatisiert die Konvertierung von ISO zu VHDX ohne manuelle Installation.

Einschränkung (Stand Juli 2026): Das PSGallery-Paket ist beschädigt (`End of Central Directory record could not be found`). Das Skript kann stattdessen direkt von GitHub geladen werden.

```powershell
# Skript direkt herunterladen
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/x0nn/Convert-WindowsImage/master/Convert-WindowsImage.ps1' `
    -OutFile 'C:\Lab\Convert-WindowsImage.ps1'
. 'C:\Lab\Convert-WindowsImage.ps1'

Convert-WindowsImage -SourcePath 'D:\ISOs\windows_server_2022.iso' `
    -VHDPath 'C:\Lab\Base\windows-server-base.vhdx' `
    -VHDFormat VHDX `
    -SizeBytes 60GB `
    -Edition 'Windows Server 2022 Standard (Desktop Experience)' `
    -DiskLayout UEFI
```

Das resultierende VHDX ist bereits generalisiert (OOBE beim ersten Start). Sysprep ist bei dieser Methode nicht notwendig.

---

## Ubuntu Cloud Image (Linux-VMs)

Der QuickStart lädt das Ubuntu Cloud Image automatisch herunter. Die URL ist in `Internal/VmProvisioning.ps1` (`Get-LinuxCloudImage`) hinterlegt.

| Eigenschaft | Wert |
| --- | --- |
| Distribution | Ubuntu 24.04 LTS (Noble Numbat) |
| Variante | Server Cloud Image, Hyper-V-optimiert |
| Format | VHDX (komprimiert als ZIP) |
| URL | https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64-hyperv.vhdx.zip |
| Größe (ZIP) | ca. 600 MB |
| Größe (entpackt) | ca. 1.2 GB (dynamisch, wächst bei Bedarf) |

Das Image wird in den Lab-Root entpackt und als Parent für Differencing Disks verwendet. Die Erstkonfiguration erfolgt über cloud-init (ISO mit user-data und meta-data).

---

## SQL Server Installationsmedien

### Windows (ISO)

Für Windows-VMs wird SQL Server über ein ISO-Image mit unattended Setup (`ConfigurationFile.ini`) installiert. Die ISOs sind nicht automatisch herunterladbar; Microsoft erfordert eine interaktive Session.

| Edition | Bezugsquelle |
| --- | --- |
| SQL Server 2019 Developer | https://www.microsoft.com/de-de/sql-server/sql-server-downloads |
| SQL Server 2022 Developer | https://www.microsoft.com/de-de/sql-server/sql-server-downloads |
| SQL Server 2025 Developer | https://www.microsoft.com/de-de/sql-server/sql-server-downloads |

Die Developer Edition ist für Testumgebungen kostenlos nutzbar (Lizenzierung erlaubt keine Produktion).

### Linux (APT-Repository)

Für Linux-VMs wird SQL Server über das Microsoft APT-Repository installiert. Die URLs sind in `Internal/SqlInstall.ps1` (`Get-MssqlRepoUrl`) hinterlegt.

| Version | Repository-URL |
| --- | --- |
| SQL Server 2019 | https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2019.list |
| SQL Server 2022 | https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2022.list |
| SQL Server 2025 | https://packages.microsoft.com/config/ubuntu/24.04/mssql-server-2025.list |

Zusätzlich benötigte Paketquellen:

| Zweck | URL |
| --- | --- |
| Microsoft GPG-Key | https://packages.microsoft.com/keys/microsoft.asc |
| SQL Server Tools (sqlcmd) | https://packages.microsoft.com/config/ubuntu/22.04/prod.list |

Die Installation erfolgt vollautomatisch via SSH ohne Benutzerinteraktion.

---

## cloud-init ISO-Erstellung

Die Linux-VMs benötigen eine cloud-init-ISO für die Erstkonfiguration (Hostname, SSH-Key, Netzwerk, Benutzer). Die ISO wird mit `oscdimg.exe` aus dem Windows Assessment and Deployment Kit (ADK) erstellt.

| Eigenschaft | Wert |
| --- | --- |
| Werkzeug | oscdimg.exe (Windows ADK) |
| ADK-Download | https://learn.microsoft.com/de-de/windows-hardware/get-started/adk-install |
| Benötigte Komponente | Deployment Tools (enthält oscdimg.exe) |
| Typischer Pfad | `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe` |

Falls das ADK nicht installiert ist, kann `oscdimg.exe` alternativ aus einer bestehenden ADK-Installation oder einem Windows PE-Addon kopiert werden (einzelne EXE, keine Abhängigkeiten).

---

## Zusammenfassung der externen Abhängigkeiten

| Komponente | Automatisch | Bemerkung |
| --- | --- | --- |
| Ubuntu Cloud Image | Ja | Download durch Setup |
| SQL Server Linux (APT) | Ja | Installation via SSH |
| Microsoft GPG-Key | Ja | Import via SSH |
| Windows Server ISO | Nein | Manueller Download, Evaluation oder MSDN |
| SQL Server Windows ISO | Nein | Manueller Download, Developer Edition |
| Windows ADK (oscdimg) | Nein | Für cloud-init-ISO benötigt |

Der Linux-Modus erfordert keine manuellen Downloads außer dem ADK für die cloud-init-ISO. Der Windows-Modus erfordert ein vorbereitetes Base-VHDX und SQL Server ISOs.
