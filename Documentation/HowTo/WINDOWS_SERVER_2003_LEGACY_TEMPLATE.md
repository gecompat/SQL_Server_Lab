# Windows Server 2003 SP2 als Legacy-Hyper-V-Vorlage

Diese Anleitung beschreibt den isolierten x86-/Generation-1-Pfad für SQL
Server 2000 und SQL Server 2005. Er ist bewusst nicht Teil der normalen
`OS_SEALED`-Registry: deren aktueller Vertrag setzt x64 und Hyper-V Generation 2
voraus.

Windows Server 2003 ist außer Support. Die Vorlage darf nur am internen
Lab-Switch ohne direkten Internetzugang betrieben werden.

## Gebundene Medien

Das Repository kennt zwei getrennte Quellen:

- `windows-server-2003-enterprise-evaluation-community-scan`: quarantänisierte
  Evaluation-Basis; die daraus abgeleitete ISO ist an SHA-256 gebunden;
- `windows-server-2003-sp2-x86-tools-iso`: direktes Microsoft-SP2-ISO mit
  `SUPPORT\TOOLS\DEPLOY.CAB` und Sysprep `5.2.3790.3959`.

Das SP2-Tools-ISO wird ohne Formularinteraktion geladen:

```powershell
Save-SqlServerLabMediaSource `
    -Id windows-server-2003-sp2-x86-tools-iso `
    -MediaRoot '<Lab1_Base>'
```

Erwartete Eigenschaften:

```text
Datei:   WindowsServer/2003/Eval/Updates/w2k3sp2_3959_usa_x86fre_spcd.iso
Bytes:   548630528
SHA-256: 30cbd649cfd879bc35a94c41366380d64b5c1745393bcf5604390d3ce566529c
SHA-1:   aeae93def8b8f5885bcea9a24f4979e51637254b
Volume:  CR0SP2_EN
```

Das bei einer SP2-Slipstream-Erzeugung unverändert kopierte `DEPLOY.CAB` kann
noch Sysprep `5.2.3790.0` enthalten. Für die SP2-Vorlage wird deshalb nur das
separate, hashgebundene SP2-Tools-ISO verwendet.

## Referenz-VM

Verbindliche VM-Eigenschaften:

```text
Generation:                  1
Architektur:                 x86
Virtuelle Prozessoren:       1
Arbeitsspeicher:             2 GiB, statisch
Netzwerk:                    Legacy Network Adapter, interner Lab-Switch
Automatische Checkpoints:    aus
Startreihenfolge nach Setup: IDE vor CD
Tastaturlayout während Setup: en-US
```

Die Ein-Prozessor-Konfiguration vermeidet die beobachtete Bootschleife. Die
CD muss nach Setup entfernt oder hinter die IDE-Platte gestellt werden, damit
nicht erneut von CD gestartet wird.

Ohne alte Hyper-V Integration Services kann die VMConnect-Maus gespiegelt
reagieren. Die Installation und Mini-Setup bleiben vollständig per Tastatur
bedienbar. Dieser Zustand ist eine dokumentierte Einschränkung, kein Nachweis
einer fehlerhaften OS-Installation.

## Vor dem Versiegeln

1. Windows Server 2003 Enterprise Evaluation SP2 muss vollständig gestartet
   und einmal interaktiv angemeldet sein.
2. Die Post-Setup-Update-Seite wird geschlossen; Windows Update wird nicht
   ausgeführt.
3. Rollen, SQL Server, Kundendaten und Kennwörter gehören nicht in die
   OS-Vorlage.
4. Die angezeigte Aktivierung wird in der Referenz-VM nicht ausgeführt.
5. Vor Sysprep wird ein benannter Hyper-V-Checkpoint als lokaler Recovery-Punkt
   erstellt.

Die originalen Windows-Server-2003-Deployment-Tools dokumentieren, dass
`Sysprep -reseal` ohne `-activated` vorhandene Aktivierungsdaten entfernt, die
WPA-Uhr zurücksetzt und der Aktivierungs-Countdown erst beim nächsten Start
beginnt. Der erste Start ist daher ausschließlich auf einem abgeleiteten Klon
zulässig.

## Schlüsselfreies Sysprep-Medium

Das Hilfsmedium enthält weder Product Key noch Administratorkennwort:

```powershell
.\Tools\New-WindowsServer2003SysprepMedia.ps1 `
    -Sp2IsoPath '<Lab1_Base>\WindowsServer\2003\Eval\Updates\w2k3sp2_3959_usa_x86fre_spcd.iso' `
    -OutputIsoPath '<Lab1_Base>\WindowsServer\2003\Eval\Tools\WindowsServer2003-SP2-x86-Sysprep-Reseal.iso'
```

Nach dem Einlegen kopiert AutoRun `sysprep.exe`, `setupcl.exe` und
`factory.exe` nach `C:\Sysprep` und startet:

```text
sysprep -reseal -mini -quiet -forceshutdown
```

Wenn AutoRun im Gast deaktiviert ist, wird `prepare-template.cmd` auf der DVD
einmal manuell gestartet. Ein normales Sysprep-Herunterfahren ist die einzige
gültige Generalisierungs-Evidenz; ein hartes `Stop-VM -TurnOff` zählt nicht.

## Parent erzeugen

Nach dem Sysprep-Herunterfahren bleibt die Referenz-VM ausgeschaltet. Wenn ein
Recovery-Checkpoint existiert, zeigt ihr aktiver Datenträger auf eine AVHDX.
`Convert-VHD` flacht diese Kette in eine eigenständige dynamische VHDX ab:

```powershell
$source = (Get-VMHardDiskDrive -VMName '<Referenz-VM>').Path
$target = '<Lab1_Base>\WindowsServer\2003\Eval\VHDX\WindowsServer2003Enterprise-Eval-SP2-x86-Gen1-Sysprep.vhdx'

if ((Get-VM -Name '<Referenz-VM>').State -ne 'Off') {
    throw 'Die Referenz-VM muss ausgeschaltet sein.'
}

New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
Convert-VHD -Path $source -DestinationPath $target -VHDType Dynamic
Set-ItemProperty -LiteralPath $target -Name IsReadOnly -Value $true
Get-FileHash -LiteralPath $target -Algorithm SHA256
```

Der Recovery-Checkpoint der Referenz-VM wird dabei nicht gelöscht. Das Parent
wird zusammen mit einem SHA-256-Sidecar und einem lokalen Manifest unter
`WindowsServer/2003/Eval/VHDX` abgelegt. Das Manifest verwendet den getrennten
Zustand `LEGACY_TEMPLATE_SEALED`.

## Klone

Das Parent wird niemals direkt gebootet. Jeder SQL-Lab-Slot erhält eine
Differencing-VHDX:

```powershell
New-VHD `
    -Path '<Lab1_Data>\HyperV\Slots\<Slot>\os.vhdx' `
    -ParentPath '<Lab1_Base>\WindowsServer\2003\Eval\VHDX\WindowsServer2003Enterprise-Eval-SP2-x86-Gen1-Sysprep.vhdx' `
    -Differencing
```

Für den Klon gelten dieselben Generation-1-, Ein-Prozessor-, statischen
Speicher- und Legacy-Netzwerk-Eigenschaften. Beim ersten Start läuft Mini-Setup
und erzeugt die klonspezifische Identität. Erst dort werden Computername,
Kennwort und gegebenenfalls die Aktivierung behandelt. Product Keys und
Kennwörter werden weder in das Repository noch in das Parent-Manifest
geschrieben.

Der erste Cold-Boot-Test erfolgt auf einem wegwerfbaren Child. Erwartet werden:

- Mini-Setup statt direktem Desktop;
- kein Boot von CD;
- neuer Computername/SID nach Mini-Setup;
- erfolgreicher Neustart mit einem vCPU;
- weiterhin interner, isolierter Netzwerkanschluss.

Erst nach diesem Test wird ein Child für SQL Server 2000 oder SQL Server 2005
weiterverwendet.

## Recovery

- Vor einem erfolgreichen Child-Test bleibt die ursprüngliche Referenz-VM samt
  Checkpoint erhalten.
- Ein fehlgeschlagener Child-Test verändert das schreibgeschützte Parent nicht;
  nur das betroffene Differencing-Child wird verworfen.
- Eine versehentlich direkt gebootete Parent-VHDX ist nicht mehr versiegelt und
  muss aus der validierten Quelle neu erzeugt werden.
- Die normale `OS_SEALED`-Registry darf dieses x86-/Generation-1-Artefakt erst
  aufnehmen, wenn Architektur und Hyper-V-Generation explizite Vertragsfelder
  sowie einen passenden Clone-Pfad besitzen.
