# Windows-Server-Vorlagen: reale Validierungsmatrix

Stand: 6. September 2026. Diese Matrix trennt vorhandene Medien, angelegte
VM-Hüllen und tatsächlich verwendbare Vorlagen. Ein ISO, eine leere VHDX oder
ein erfolgreicher Hashvergleich gelten ausdrücklich nicht als fertige
OS-Vorlage.

## Evidenzstufen

| Stufe | Bedeutung |
|---|---|
| `MEDIA_HASH_VERIFIED` | lokale Datei stimmt in Größe und SHA-256 mit dem Katalog überein |
| `INSTALL_IMAGE_VERIFIED` | `install.wim`/`install.esd`, Edition, Architektur und Imageindex wurden direkt gelesen |
| `INSTALL_BOOT_VERIFIED` | Windows wurde in der vorgesehenen Hyper-V-Generation installiert und kalt gebootet |
| `GENERALIZE_VERIFIED` | Sysprep/Reseal und ausgeschalteter OOBE-Zustand sind technisch belegt |
| `CHILD_BOOT_VERIFIED` | neuer Differencing-Child wurde eingerichtet, erneut kalt gebootet und geprüft |
| `ACTIVATION_VERIFIED` | Evaluation beziehungsweise lizenzierter Kanal meldet einen verwendbaren Lizenzzustand |

Eine Version ist erst ab `CHILD_BOOT_VERIFIED` eine verwendbare Vorlage. Eine
Evaluation mit ausstehender Aktivierung wird zusätzlich sichtbar eingeschränkt.
Automatisch gebaute Artefakte werden deshalb zunächst mit
`TemplateValidation.Status=PENDING` registriert und von der normalen Auswahl
ausgeschlossen. Erst die erfolgreiche, bereinigte Child-Abnahme bindet den
SHA-256-Wert der JSON-Evidenz an das Artefakt und schaltet es als
`CHILD_BOOT_VERIFIED` frei; bei einem Fehler bleibt es fail-closed.

## Aktueller Hostnachweis

| Windows Server | VM-Vertrag | Reale höchste Stufe | Ergebnis und offene Grenze |
|---|---|---|---|
| 2003 SP2 x86 | Generation 1, Legacy-NIC, WMI/DCOM | `CHILD_BOOT_VERIFIED` | Installation, Integration Services, Reseal und Child-Boot funktionieren. Online-Aktivierung blieb bei `ActivationRequired=1`. Das deutsche Login-Layout und der WMI-Offline-Aktivierungsadapter sind implementiert und statisch geprüft, am aktuellen Child nach der Korrektur aber noch nicht erneut nativ abgenommen. |
| 2008 R2 SP1 x64 | Generation 1, kein Secure Boot, emulierter NIC, Legacy-WMI | `CHILD_BOOT_VERIFIED` + `OOB_GRACE` | Index 1, Build 6.1.7601.17514. Installation, Sysprep, Child-OOBE, nutzbarer Lizenz-Grace-State und erneuter Kaltstart bestanden. Die alte KVP-Version erfordert die direkte VM-ID-gebundene Auswertung von `NetworkAddressIPv4`; ein Gen-1-IDE-Antwortmedium wird ausgeworfen statt hot-entfernt. Artifact `hyperv-os-sealed-6135e9bedc5a771a1e621ba1688b70ca3efeeb95264f183bb8e0f215489502a4`, Grace bis `2026-09-16T15:20:14Z`. Der Online-Aktivierungsversuch blieb bei `LicenseStatus=2`; deshalb keine `ACTIVATION_VERIFIED`-Behauptung und keine automatische Auswahl mit dem 30-Tage-Standard. |
| 2012 R2 x64 | Generation 2, Secure Boot aus, Legacy-WMI | `CHILD_BOOT_VERIFIED` + `ACTIVATION_VERIFIED` | Index 2, Build 6.3.9600.17031. Der aktuelle Hyper-V-DBX-Stand blockiert den alten ISO-Bootmanager bei aktivem Secure Boot. Mit deaktiviertem Secure Boot bestanden Installation, Aktivierung, Sysprep, Child-OOBE und Kaltstart. Artifact `hyperv-os-sealed-05268d5945e375e35310e16acefe6189693936ec85fa759ccba4c6f94634fc1d`, Evaluation bis `2027-03-05T14:33:49Z`. |
| 2016 x64 | Generation 2, Secure Boot, PowerShell Direct | `CHILD_BOOT_VERIFIED` + `ACTIVATION_VERIFIED` | Index 2, Build 10.0.14393.0. Installation, Evaluation-Aktivierung, Sysprep, Child-OOBE und erneuter Kaltstart bestanden. Artifact `hyperv-os-sealed-8eb95be05c8923b43519f1c4b9a9946ee2b65dbce39016ba99ae42cd3ed323ad`, Evaluation bis `2027-03-05T12:20:21Z`. |
| 2019 x64 | Generation 2, Secure Boot, PowerShell Direct | `CHILD_BOOT_VERIFIED` + `ACTIVATION_VERIFIED` | Index 2, Build 10.0.17763.3650. Auch bei gleichzeitig vorhandener deutscher ISO wurde deterministisch das hashgebundene englische Katalogmedium verwendet. Artifact `hyperv-os-sealed-fcb12b87bdf535ccd97ee5b17e6556888166bbd2937d1d8d949be747b31d47d8`, Evaluation bis `2027-03-05T12:32:21Z`. |
| 2022 x64 | Generation 2, Secure Boot, PowerShell Direct | `CHILD_BOOT_VERIFIED` + `ACTIVATION_VERIFIED` | Index 2, Build 10.0.20348.587. Die asynchrone Meldung `another activation attempt is in progress` wird über den gesamten Licensing-WMI-Zyklus begrenzt wiederholt. Artifact `hyperv-os-sealed-54ee20d5655b00f4e7b0549dca5787629756d9f8933bb37a61ae9111d1a88f32`, Evaluation bis `2027-03-05T12:59:13Z`. |
| 2025 x64 | Generation 2, Secure Boot, PowerShell Direct | `CHILD_BOOT_VERIFIED` + `ACTIVATION_VERIFIED` | Index 2, Build 10.0.26100.32230. Der aktuelle automatisierte Lauf bestand Installation, Aktivierung, Sysprep, Child-OOBE und Kaltstart. Artifact `hyperv-os-sealed-de0d6b854e50ea53b9f1d1fabf3beb4bfa0ee74a0666a3a67e9ca7c13ccc5f34`, Evaluation bis `2027-03-05T13:10:38Z`. Das ältere, bereits referenzierte Artifact bleibt unangetastet. |

## Reproduzierbare Medienprüfung

Der portable Prüfer wird einmalig ohne Administratorrechte installiert. Der
Download und das entpackte Programm sind an die veröffentlichten SHA-256-Werte
von wimlib 1.14.5 gebunden:

```powershell
.\Tools\Install-WindowsServerMediaInspector.ps1 -MediaRoot 'D:\Lab1_Base'
```

Danach funktioniert die vollständige ISO-/WIM-Prüfung ebenfalls ohne
Administratorrechte:

```powershell
.\Tools\Test-WindowsServerEvaluationMedia.ps1 `
    -MediaRoot 'D:\Lab1_Base' `
    -OutputPath 'D:\Lab1_Base\Evidence\windows-server-evaluation-media-validation.json'
```

Die JSON-Datei ist die maschinenlesbare Basis für Edition, Imageindex,
Architektur, erforderliche VM-Generation und spätere Template-Läufe. Der
Prüfer verwendet im Benutzerkontext 7-Zip plus wimlib und entfernt das jeweils
temporär extrahierte `install.wim`/`install.esd` sofort wieder. In einer
erhöhten Sitzung kann er alternativ mit `-InspectionMode Microsoft` die
Microsoft-API verwenden und hängt dann nur Medien wieder aus, die er selbst
eingebunden hat.

## Buildpfade

- Windows Server 2003 bleibt wegen NT5-Setup, 32-Bit-Gast und klassischem
  Sysprep in seinem getrennten Legacy-Runbook.
- Windows Server 2008 R2 wird als Generation 1 ohne Secure Boot geplant.
- Windows Server 2012 R2 wird als Generation 2 mit Secure Boot aus geplant,
  weil der aktuelle Hyper-V-DBX-Stand den alten ISO-Bootmanager ablehnt.
- Windows Server 2016 und neuer werden als Generation 2 mit Microsoft-
  Secure-Boot-Template geplant.
- Windows Server 2016 und neuer werden nach Installation über PowerShell Direct
  geprüft und generalisiert.
- Windows Server 2008 R2 und 2012 R2 werden nur über ihren isolierten,
  inzwischen real bestandenen Legacy-WMI-Installations-, Sysprep- und
  Child-Nachweis veröffentlicht. Der Gaststeuerungstyp wird im Artifact
  persistiert und in der öffentlichen Inventur ausgegeben.

Die aktuelle Microsoft-Kompatibilitätsmatrix wird zusätzlich vor der
SQL-Installation ausgewertet. Sie bestätigt beispielsweise SQL Server 2019,
2022 und 2025 auf Windows Server 2025, aber nicht SQL Server 2017 oder älter.
Für SQL Server 2017 bis 2008 gelten je nach Ziel-OS konkrete Mindest-Service-
Pack-Stände. Quelle:
[Microsoft – SQL Server and Windows compatibility matrix](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/install/windows/use-sql-server-in-windows).

## Verbleibende Grenze

Die OS-Vorlagen 2008 R2 bis 2025 sind auf diesem Host real bis zum Child-Boot
geprüft. Der allgemeine Slot- und SQL-Installationspfad verwendet außerhalb
dieser Template-Abnahme teilweise noch PowerShell Direct. Für 2008 R2 und
2012 R2 muss deshalb vor einer allgemeinen Freigabe derselbe Legacy-WMI-Kanal
in die reguläre Child-Provisionierung und die jeweils kompatiblen SQL-Setup-
Pfade integriert und separat real abgenommen werden.

Microsoft dokumentiert für Windows Server 2008 R2 SP1 Evaluation keinen
einzugebenden Product Key, aber eine Aktivierung innerhalb von zehn Tagen und
erst danach 180 Tage Laufzeit. Der reale Lauf vom 6. September 2026 bestätigte
nur den eingebauten zehn-Tage-Grace-State. Quelle:
[Microsoft Download Center – Windows Server 2008 R2 SP1 Evaluation](https://www.microsoft.com/en-gb/download/details.aspx?id=22077).

## SQL Server 2000 bis 2014: belastbarer Ist-Stand

Die vorhandenen lokalen VMs mit Namen `legacy-sql-*` sind derzeit
Installationshüllen mit dem Zustand `OS_INSTALL_PENDING`, keine belegten
SQL-Umgebungen. Vorhandene Medien allein werden nicht als Installation
gewertet.

| SQL Server | Lokales Medium | Geeignete OS-Baseline | Automatisierter SQL-Nachweis |
|---|---|---|---|
| 2000 | Eval-ISO und MSDE-EXE; Eval bleibt `COMMUNITY_UNVERIFIED` | Windows Server 2003 SP2 x86, getrenntes `LEGACY_TEMPLATE_SEALED` | fehlt |
| 2005 | Eval-ISO und Express-SP4-EXE; Eval bleibt `COMMUNITY_UNVERIFIED` | Windows Server 2003 SP2 x86 | fehlt |
| 2008 | hashgebundene frühere Microsoft-Eval-ISO und Express-EXE | Windows Server 2008 R2 SP1, aktuell nur kurzlebiges `OOB_GRACE` | fehlt |
| 2008 R2 | Microsoft-signiertes Eval-SFX und Express-EXE | Windows Server 2008 R2 SP1 | SFX-Staging und Installation fehlen |
| 2012 | hashgebundene Eval-ISO und Express-EXE | Windows Server 2012 R2, child- und aktivierungsgeprüft | SQL-Setup läuft noch nicht über Legacy-WMI |
| 2014 | Express-RTM-/SP3-SFX, kein Eval-ISO | Windows Server 2012 R2 | SFX-/Express-Adapter und Installation fehlen |

Die nächste Implementierungswelle beginnt deshalb mit SQL Server 2012 auf
der validierten 2012-R2-Baseline. Erst danach wird derselbe Legacy-Gastkanal
für 2014, 2008/2008 R2 und zuletzt der getrennte NT5/x86-Pfad für 2005/2000
erweitert. Keine dieser SQL-Versionen wird vor einem echten Setup-, Dienst-,
Versions- und Verbindungsnachweis als `READY` ausgewiesen.
