# Externer Media Root für ISO, VHDX und Installer

| Merkmal | Wert |
|---|---|
| Root | vom Operator verpflichtend angegeben |
| Beispiel | `D:\Lab_Base` |
| Git-Checkout erlaubt | nein |
| Initializer | `Tools/Initialize-SqlServerLabMediaRoot.ps1` |

## 1. Zweck und Abgrenzung

Große, lizenzierte oder zeitlich begrenzte Installationsmedien gehören nicht in
das Repository. Der Media Root ist ein operatorseitiges Verzeichnis außerhalb
von Git. Er ist außerdem vom Lab-State getrennt: Der Media Root enthält
bereitgestellte Quellen, während der State Root Runs, Trust-Freigaben,
Quarantäne, Registry und Cleanup-Informationen enthält.

Das Projekt setzt keinen festen Laufwerksbuchstaben voraus. Jeder Aufruf muss
den Root ausdrücklich angeben:

```powershell
.\Tools\Initialize-SqlServerLabMediaRoot.ps1 -RootPath 'D:\Lab_Base'
```

Ein Laufwerksroot wie `D:\` und jeder Pfad innerhalb des Repository werden
abgelehnt.

### Lokaler Standard für dieses Projekt

Sobald ein Media Root im Image-Menü erstmals ausgewählt wurde, speichert das
Lab ihn zusätzlich projektlokal unter
`.local/preferences.json`. Diese Datei ist absichtlich in Git ignoriert: Sie
enthält einen lokalen Hostpfad und gehört weder in Commits noch in ein Manifest.
Sie bleibt über neue Terminals, UAC-erhöhte Prozesse und Neustarts erhalten.

Die Reihenfolge für den angezeigten Default ist:

1. explizite Prozessvariable `SQL_SERVER_LAB_MEDIA_ROOT`;
2. `.local/preferences.json` dieses Checkouts;
3. die bisherige benutzerbezogene Umgebungsvariable als Kompatibilitätsfallback.

Punkt `12` (Builder aufräumen) verändert diese Einstellung nicht. Ein nicht
mehr existierender lokaler Pfad wird nicht als Default angeboten.

## 2. Kanonische Struktur

```text
<MediaRoot>\
├── README.md
├── Incoming\
├── Linux\
│   ├── ISO\
│   └── VHDX\
├── SQL\
│   ├── Installers\
│   │   ├── 2019\
│   │   ├── 2022\
│   │   └── 2025\
│   ├── 2019\Updates\<CU>\
│   ├── 2022\Updates\<CU>\
│   ├── 2025\Updates\<CU>\
│   ├── 2019\Eval\ISO\
│   ├── 2022\Eval\ISO\
│   └── 2025\
│       ├── Eval\ISO\
│       ├── Enterprise\ISO\
│       └── Standard\ISO\
├── WindowsServer\
│   ├── 2022\Eval\
│   │   ├── ISO\
│   │   └── VHDX\
│   └── 2025\Eval\
│       ├── ISO\
│       └── VHDX\
├── Testdaten\
│   ├── Sammlungen\<Kategorie>\<Sample>\<Variante>\
│   └── _verified\sha256\
├── Hashes\
├── Evidence\
└── Exports\
```

`Incoming` nimmt noch nicht klassifizierte Root-Medien auf. `Hashes` spiegelt
bei der automatischen SHA-256-Erzeugung die relativen Medienpfade. `Evidence`
ist für explizite Buildnachweise vorgesehen. `Exports` enthält bewusst erzeugte
lokale Übergabeartefakte und wird nicht versioniert. Der Initializer ergänzt im
Root und in jedem Medienziel eine `README.md` mit offizieller Downloadquelle,
Zielpfad, Auswahlkriterien und Verwendungshinweisen.

### Testdaten-Bibliothek

`Testdaten` ist die sichtbare, wiederverwendbare Bibliothek für katalogisierte
Backups, ZIP-/7z-Archive und T-SQL-Skripte. Ein Download startet weiterhin nur
bei einer expliziten Testdatenbank-Installation. Nach SHA-256-Prüfung erscheint
die Datei unter `Sammlungen\<Kategorie>\<Sample>\<Variante>` zusammen mit einer
`artifact.json` (Quelle, Hash, Lizenz-/Trust-Herkunft und Zeitpunkt).

`_verified\sha256` ist der technische, inhaltsadressierte Speicher derselben
Artefakte. Die sichtbaren Dateien in `Sammlungen` werden nach Möglichkeit als
Hardlink darauf angelegt; andernfalls wird sicher kopiert. Temporäre Downloads,
Quarantäne und Trust-Freigaben bleiben im State Root.

Bestände aus älteren Versionen unter `<StateRoot>\cache\artifacts\sha256`
werden nicht gelöscht: Bei der nächsten Verwendung wird ihr Hash erneut
geprüft und die Datei in die neue sichtbare Bibliothek übernommen.

Der Testdaten-Root kann in der Workflow-UI unter **Medienquellen** oder in der
Konsole über **[t] Testdaten-Bibliothek konfigurieren** geändert werden. Ohne
eigene Einstellung lautet der Default `<MediaRoot>\Testdaten`.

## 3. Struktur automatisch erstellen

Der Initializer ist idempotent. Bereits vorhandene Verzeichnisse bleiben
unverändert. Fehlende Download-READMEs werden automatisch erzeugt:

```powershell
Set-Location D:\r\pu\SQL_Server_Lab

.\Tools\Initialize-SqlServerLabMediaRoot.ps1 `
    -RootPath 'D:\Lab_Base'
```

Eine statische ZIP ist deshalb nicht erforderlich. Das Skript erzeugt die
Struktur und die lokalen Anleitungen direkt für jeden angegebenen Root. Das
Repository selbst kann weiterhin als ZIP bezogen werden; danach wird der
Initializer aus `Tools/` aufgerufen.

### Verhalten vorhandener READMEs

Eine vorhandene `README.md` mit identischem Inhalt bleibt unverändert. Weicht
sie vom generierten Inhalt ab, wird sie als mögliche Anwenderdatei behandelt,
nicht überschrieben und unter `SkippedReadmeFiles` im Receipt gemeldet. Zum
bewussten Neuaufbau kann die einzelne README zunächst manuell gesichert und
gelöscht und der Initializer danach erneut ausgeführt werden.

Die erzeugten READMEs enthalten nur öffentliche Links und Bedienhinweise. Sie
enthalten keine Zugangsdaten und laden nichts selbstständig herunter. Downloads
bleiben wegen Registrierung, Lizenzwahl, Sprache und Evaluation-Bedingungen
eine ausdrückliche Handlung der Anwenderin oder des Anwenders.

## 4. Vorhandene Medien sicher einsortieren

Zuerst immer die geplanten Moves ansehen:

```powershell
.\Tools\Initialize-SqlServerLabMediaRoot.ps1 `
    -RootPath 'D:\Lab_Base' `
    -OrganizeExisting `
    -WhatIf
```

Wenn der Plan stimmt:

```powershell
.\Tools\Initialize-SqlServerLabMediaRoot.ps1 `
    -RootPath 'D:\Lab_Base' `
    -OrganizeExisting
```

Das Skript verarbeitet nur bekannte Fälle:

| Quelle | Ziel |
|---|---|
| `<Root>\SQL2019-*.exe` | `SQL\Installers\2019` |
| `<Root>\SQL2022-*.exe` | `SQL\Installers\2022` |
| `<Root>\SQL2025-*.exe` | `SQL\Installers\2025` |
| `Linux\*.iso` | `Linux\ISO` |
| `Linux\*.vhdx` | `Linux\VHDX` |
| `SQL\<Version>\<Edition>\*.iso` | gleiches Verzeichnis, Unterordner `ISO` |
| `WindowsServer\<Version>\<Edition>\*.iso` | gleiches Verzeichnis, Unterordner `ISO` |
| `WindowsServer\<Version>\<Edition>\*.vhdx` | gleiches Verzeichnis, Unterordner `VHDX` |
| unbekannte ISO/VHD/VHDX direkt im Root | `Incoming` |

Bestehende Zieldateien werden nie überschrieben. Mehrdeutige oder kollidierende
Ziele brechen den Lauf vor dem ersten Move ab.

## 5. SHA-256-Sidecars erzeugen

Die Berechnung liest alle Medien vollständig und kann bei großen ISOs/VHDX
mehrere Minuten dauern:

```powershell
.\Tools\Initialize-SqlServerLabMediaRoot.ps1 `
    -RootPath 'D:\Lab_Base' `
    -GenerateSha256
```

Einsortierung und Hashing können kombiniert werden:

```powershell
.\Tools\Initialize-SqlServerLabMediaRoot.ps1 `
    -RootPath 'D:\Lab_Base' `
    -OrganizeExisting `
    -GenerateSha256
```

Beispiel:

```text
WindowsServer\2025\Eval\ISO\SERVER_EVAL_x64FRE_en-us.iso
Hashes\WindowsServer\2025\Eval\ISO\SERVER_EVAL_x64FRE_en-us.iso.sha256
```

Ein vorhandenes abweichendes Sidecar führt zu `MEDIA_HASH_CONFLICT`; es wird
nicht still überschrieben.

## 6. Aktuell benötigte Windows-Medien

Für den ersten realen Hyper-V-Image-Build wird bevorzugt verwendet:

- Windows Server 2025 Evaluation;
- English (United States);
- ISO, x64;
- im Installer zunächst Standard Evaluation mit Desktop Experience für die
  einfachere Diagnose.

Offizielle Quelle:
[Windows Server 2025 Evaluation](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025).

Ziel:

```text
<MediaRoot>\WindowsServer\2025\Eval\ISO\<Originaldateiname>.iso
```

Eine von Microsoft gelieferte Evaluation-VHDX wird getrennt abgelegt:

```text
<MediaRoot>\WindowsServer\2025\Eval\VHDX\<Originaldateiname>.vhdx
```

Der aktuelle Windows-Image-Builder nimmt eine ISO als Installationsquelle. Eine
fertige VHDX kann über die Hyper-V-Image-Registry importiert werden, wenn sie
die geforderten Generalisierungs-, Read-only-, SHA-256- und Metadatenverträge
erfüllt. Eine Evaluation-VHDX ist nicht allein aufgrund ihrer Herkunft bereits
ein `OS_SEALED`-Artifact.

## 7. SQL-Server-Medien

SQL-Server-Webinstaller werden nach Version unter `SQL\Installers` abgelegt.
Heruntergeladene ISOs liegen nach Version und Edition unter `SQL`.

Offizielle Quelle:
[SQL Server Downloads](https://www.microsoft.com/en-us/sql-server/sql-server-downloads).

### Developer-Downloadreferenzen

Die folgenden Links werden als lokale Referenz für manuelle Medienbeschaffung
geführt. Nach dem Download bleiben Originaldateiname und SHA-256 nachvollziehbar;
die Datei wird erst danach in die passende Media-Root-Struktur einsortiert.

| Version | Edition | Offizielle Downloadreferenz | Einordnung |
| --- | --- | --- | --- |
| SQL Server 2022 | Developer | [Bootstrap-Installer](https://aka.ms/sqlserver2022developer) | Aktiver Lab-Umfang; daraus ein ISO-Medium erzeugen und unter `SQL\2022\<Edition>\ISO` ablegen. |
| SQL Server 2019 | Developer | [Bootstrap-Installer](https://download.microsoft.com/download/d/a/2/da259851-b941-459d-989c-54a18a5d44dd/SQL2019-SSEI-Dev.exe) | Aktiver Lab-Umfang; daraus ein ISO-Medium erzeugen und unter `SQL\2019\<Edition>\ISO` ablegen. |
| SQL Server 2017 | Developer | [Microsoft-Produktseite](https://www.microsoft.com/de-de/sql-server/sql-server-2017) | Legacy-Referenz; derzeit nicht als automatischer Lab-Build auswählbar. |
| SQL Server 2016 SP3 | Developer | [Full Slipstream ISO](https://download.microsoft.com/download/f/9/8/f982347c-fee3-4b3e-a8dc-c95383aa3020/sql16_sp3_dlc/en-us/SQLServer2016SP3-FullSlipstream-x64-ENU-DEV.iso) | Legacy-Referenz; derzeit nicht als automatischer Lab-Build auswählbar. |

SQL Server 2016 und 2017 werden bewusst nur als Downloadreferenzen geführt.
Der aktuell automatisierte Container- und Hyper-V-Workflow unterstützt SQL
Server 2019, 2022 und 2025. Für eine Erweiterung auf 2016/2017 müssen erst
Versionskatalog, Medienprüfung und Abnahmematrix ergänzt werden.

Der Hyper-V-Image-Pfad kann diese Medien SHA-256-verifiziert an einen
resumierbaren SQL-`PrepareImage`-Builder binden. Der Ablauf steht unter
[SQL Server als frisches, einmalig generalisiertes Image](HYPERV_SQL_PREPARED_IMAGE.md).

### CU-Pakete und Linux-Images

`Save-SqlServerLabCuResource` und der gleichnamige Konsolenworkflow können
jeden katalogisierten CU für SQL Server 2019, 2022 und 2025 bereitstellen.
Windows-Pakete landen unter
`SQL\<Version>\Updates\<CU>\<Originaldateiname>.exe`. Der Download wird nur aus
der im Katalog gebundenen Microsoft-Update-Catalog-Quelle akzeptiert; vor dem
atomaren Verschieben an das Ziel müssen SHA-256, Authenticode-Status und
Microsoft-Signer stimmen. Eine bereits vorhandene abweichende oder ungültig
signierte Datei wird nicht überschrieben.

Linux-CUs sind Containerimages und gehören nicht in den Media Root. Das Cmdlet
zieht den katalogisierten unveränderlichen MCR-Tag in den lokalen Docker- oder
Podman-Imagecache. Dieser Cache ist wiederverwendbar und wird nicht durch den
normalen Run-Cleanup gelöscht.

Datenbanken und Backups gehören nicht in den Media Root. Dafür wird ein
getrennter [persistenter Data Root](PERSISTENT_DATA_AND_EVALUATION_REFRESH.md)
verwendet.

## 8. Linux-Medien

Ubuntu-ISOs werden unter `Linux\ISO` abgelegt. Sie dienen derzeit der manuellen
Erstellung eines Linux-Hosts oder Runners. Der Hyper-V-Image-Builder kann daraus
noch keine Linux-Baseline erzeugen.

Offizielle Quelle: [Ubuntu Server](https://ubuntu.com/download/server).

## 9. Übergabe an den Image-Builder

Die Image-Aktion von `Invoke-SqlServerLab` löst den vollständigen ISO-Pfad und
das zugehörige SHA-256-Sidecar aus der kanonischen Struktur auf. Der Builder
prüft Dateiendung, ISO-9660-Signatur und Hash. Der
konkrete Hostpfad wird ausschließlich im lokalen Build-State gespeichert und
nicht in portable Locks oder Git übernommen.

Der bedienbare Ablauf steht unter
[Windows-Server-Baseline aus ISO mit Hyper-V erstellen](HYPERV_WINDOWS_IMAGE_BUILD.md).
Der Media Root und der Operatorpfad ersetzen nicht den noch offenen
Windows-/SQL-End-to-End-Nachweis; die OS-Installation bleibt derzeit manuell.
