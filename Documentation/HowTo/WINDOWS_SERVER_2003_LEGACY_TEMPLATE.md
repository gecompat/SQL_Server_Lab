# Windows Server 2003 SP2 als Legacy-Hyper-V-Vorlage

Diese Anleitung beschreibt den isolierten x86-/Generation-1-Pfad für SQL
Server 2000 und SQL Server 2005. Er ist bewusst nicht Teil der normalen
`OS_SEALED`-Registry: deren aktueller regulärer Gastvertrag setzt x64 und moderne
Gaststeuerung
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
Tastaturlayout ab Mini-Setup:    Deutsch (`0407:00000407`)
```

Die Ein-Prozessor-Konfiguration vermeidet die beobachtete Bootschleife. Die
CD muss nach Setup entfernt oder hinter die IDE-Platte gestellt werden, damit
nicht erneut von CD gestartet wird.

Ohne alte Hyper-V Integration Services kann die VMConnect-Maus gespiegelt
reagieren. Die Installation und Mini-Setup bleiben vollständig per Tastatur
bedienbar. Dieser Zustand ist eine dokumentierte Einschränkung, kein Nachweis
einer fehlerhaften OS-Installation.

## Hyper-V Integration Services und Maus

Der aktuelle Hyper-V-Host liefert `vmguest.iso` nicht mehr mit. Eine archivierte
Kopie der früheren Microsoft-Integrations-DVD ist maschinenlesbar katalogisiert.
Microsofts historische Hyper-V-Gastmatrix verlangt für Windows Server 2003 SP2
die Installation dieser Komponenten nach dem OS-Setup. Der konkrete Bericht
zum unter Windows 11 24H2 vertikal invertierten Mauszeiger und dessen Behebung
durch `vmguest.iso` ist als ergänzende Community-Evidence im Medienkatalog
verzeichnet.
Der Container besitzt keine unabhängig belegte originale Microsoft-Prüfsumme;
deshalb werden zusätzlich Volume, Setup-Version und die Microsoft-Signaturen
des x86-Setups und Windows-5.x-MSI geprüft:

```powershell
Save-SqlServerLabMediaSource `
    -Id windows-server-2003-hyper-v-integration-services-iso `
    -MediaRoot '<Lab1_Base>'

.\Tools\Test-WindowsServer2003HyperVIntegrationMedia.ps1 `
    -IsoPath '<Lab1_Base>\WindowsServer\2003\Eval\IntegrationServices\Hyper-V-Integration-Services-6.3.9600.16384-vmguest.iso'
```

Die Datei ist 27.590.656 Bytes groß; SHA-256 ist
`d1037fd8e788ce8ed0df16ec21f057e74512d5b3d551cc9396c7ae95dccba10f`.
Sie wird zuerst nur am wegwerfbaren Child getestet: Mini-Setup per Tastatur
abschließen, DVD einlegen, `support\x86\setup.exe` ausführen und neu starten.
Als positive Evidence gelten ein normal ausgerichteter VMConnect-Mauszeiger
sowie Integrationsdienste mit Hostkontakt. Erst danach darf die Referenz-VM um
diese Komponenten ergänzt und erneut versiegelt werden.

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

## Klone mit Evaluation-Key

Das Parent wird niemals direkt gebootet. Jeder SQL-Lab-Slot erhält eine
Differencing-VHDX. Der reproduzierbare Standardpfad erzeugt Child und
Generation-1-VM gemeinsam:

```powershell
$administrator = Get-Credential -UserName Administrator `
    -Message 'Neues lokales Kennwort des Windows-Server-2003-Childs'

.\Tools\New-WindowsServer2003LegacyChild.ps1 `
    -VmName '<Slot>' `
    -VmRoot '<Lab1_Data>\HyperV\Slots\<Slot>' `
    -ParentVhdPath '<Lab1_Base>\WindowsServer\2003\Eval\VHDX\WindowsServer2003Enterprise-Eval-SP2-x86-Gen1-Sysprep.vhdx' `
    -EvaluationIsoPath '<Lab1_Base>\WindowsServer\2003\Eval\ISO\WindowsServer2003Enterprise-Evaluation.iso' `
    -IntegrationServicesIsoPath '<Lab1_Base>\WindowsServer\2003\Eval\IntegrationServices\Hyper-V-Integration-Services-6.3.9600.16384-vmguest.iso' `
    -SwitchName 'SQL_LAB_HYPERV_intern' `
    -AdministratorCredential $administrator `
    -ActivateOnline `
    -ActivationSwitchName 'Default Switch' `
    -Start
```

Das Parent-Manifest und sein SHA-256, der Read-only-Status sowie der SHA-256
und Volume-Name der Evaluation-ISO werden vor jeder Mutation geprüft.
Der Befehl muss erhöht ausgeführt werden, weil Windows für das Offline-Mounten
der Child-VHDX das Volume-Verwaltungsrecht verlangt. `-WhatIf` funktioniert
auch in einer nicht erhöhten PowerShell und zeigt den geplanten Scope.

Der Evaluation-Key wird zur Laufzeit aus `I386\UNATTEND.TXT` der originalen,
hashgebundenen Evaluation-ISO gelesen. Er wird nur in
`C:\Sysprep\sysprep.inf` der neuen Child-VHDX geschrieben und weder ausgegeben
noch in Repository, Parent oder Manifest gespeichert. Das SP2-Slipstream-ISO
darf nicht als Key-Quelle dienen: dessen Beispiel-Key ist für dieses
Evaluationsmedium ungültig. Nach Mini-Setup entfernt Windows den Sysprep-Ordner.

Für den Klon gelten dieselben Generation-1-, Ein-Prozessor-, statischen
Speicher- und Legacy-Netzwerk-Eigenschaften. Beim ersten Start läuft Mini-Setup
und erzeugt die klonspezifische Identität. Nicht geheime Standardwerte wie
Arbeitsgruppe, Zeitzone, Netzwerk und deutsches Tastaturlayout werden aus der
lokalen `sysprep.inf` übernommen. Weil die Windows-2003-Deployment-Tools
`InputLocale_DefaultUser` in `sysprep.inf` ausdrücklich nicht unterstützen,
setzt der Aktivierungsschritt zusätzlich `00000407` per authentifiziertem
Gast-WMI in den Hive der Anmeldemaske. Damit gilt das deutsche Layout nach dem
automatisierten Abschluss auch vor der Anmeldung. Kennwort und Aktivierung
bleiben Child-spezifisch. Mit `-ActivateOnline` verwendet der Child-Befehl das
Credential für Mini-Setup und den nachfolgend beschriebenen, fail-closed
verifizierten Online-Aktivierungsversuch. Ohne den Schalter erzeugt er wie
bisher nur den noch nicht aktivierten Child.

Mit `-IntegrationServicesIsoPath` prüft der Child-Befehl das ISO erneut und
legt es ein. Die Installation startet weiterhin erst nach Mini-Setup. Der
Evaluation-Lizenzmodus `PerServer` mit fünf Verbindungen wird nicht interaktiv
abgefragt.

Der erste Cold-Boot-Test erfolgt auf einem wegwerfbaren Child. Erwartet werden:

- Mini-Setup statt direktem Desktop;
- kein Boot von CD;
- neuer Computername/SID nach Mini-Setup;
- erfolgreicher Neustart mit einem vCPU;
- weiterhin interner, isolierter Netzwerkanschluss.

Erst nach diesem Test wird ein Child für SQL Server 2000 oder SQL Server 2005
weiterverwendet.

## Evaluation online aktivieren

Wie bei neueren Evaluation-Betriebssystemen erhält nur der konkrete Child für
die Aktivierung vorübergehend Internetzugang. Windows Server 2003 besitzt kein
PowerShell Direct; der Gast verwendet deshalb lokal die offizielle WMI-Methode
`Win32_WindowsProductActivation.ActivateOnline()`. Das Hostskript prüft den
exakten Generation-1-VM-/Child-VHDX-Verbund, verbietet Checkpoints, fügt eine
eindeutig benannte temporäre Legacy-NIC hinzu und entfernt sie anschließend
wieder.

Das Credential wird in einer lokalen geschützten Abfrage eingegeben und nie in
die Befehlszeile, Ausgabe oder das Repository geschrieben:

```powershell
$administrator = Get-Credential -UserName Administrator `
    -Message 'Lokales Kennwort des Windows-Server-2003-Childs'

.\Tools\Invoke-WindowsServer2003LegacyActivation.ps1 `
    -VmName '<Slot>' `
    -ChildVhdPath '<Lab1_Data>\HyperV\Slots\<Slot>\os.vhdx' `
    -AdministratorCredential $administrator `
    -ActivationSwitchName 'Default Switch'
```

Der Befehl akzeptiert nur eine ausgeschaltete VM. Er startet sie mit der
temporären NIC, wartet über den Hyper-V-Datenaustausch auf eine nicht-APIPA-
Adresse und verbindet sich authentifiziert über das in Windows Server 2003
vorhandene WMI/DCOM. Das Kennwort bleibt dabei ausschließlich im Speicher. Im
Gast werden das deutsche Anmeldelayout und anschließend die Aktivierung gesetzt
und unmittelbar verifiziert. Danach fährt der Gast herunter und der Host
entfernt die temporäre NIC. Der normale Child-Befehl startet die isolierte VM
mit `-Start` anschließend wieder.

Der automatisierte Lauf setzt funktionierende Hyper-V Integration Services im
versiegelten Parent voraus: Nur damit meldet der Datenaustauschdienst die
Gastadresse an den Host. Das bloße Einlegen der Integrations-DVD in einen neuen
Child genügt dafür nicht. Nach der einmaligen Installation der verifizierten
Integrationsdienste muss deshalb ein neuer Parent versiegelt werden; dessen
Children benötigen für Tastatur und Aktivierungsversuch keine manuelle
VMConnect-Eingabe mehr.

Erfolg ist nur `EVALUATION_ACTIVE` mit `ActivationRequired=0` und einer
positiven verbleibenden Evaluationsdauer. Ein veralteter oder nicht mehr
erreichbarer Microsoft-Aktivierungsdienst bleibt ein sauberer Fehler; der
Ablauf umgeht die Aktivierung nicht und hinterlässt keinen Internetadapter.
Der reale Versuch am 6. September 2026 erreichte den Dienst nicht erfolgreich:
Das deutsche Anmeldelayout wurde gesetzt, aber `ActivationRequired` blieb `1`.
Der aktuelle lokale Child ist daher nicht als aktiviert nachgewiesen. Als
regelkonformer nächster Versuch stellt das Lab den von Windows Server 2003
dokumentierten Offline-WMI-Aktivierungsweg bereit. Microsoft hat die frühere automatische
Telefonaktivierung am 3. Dezember 2025 in das
[Product Activation Portal](https://support.microsoft.com/en-us/windows/activation/activate-microsoft-perpetual-products-using-the-product-activation-portal)
verlegt. Anmeldung und CAPTCHA bleiben bewusst ein manueller Operatorschritt.

Phase 1 liest die 50-stellige, an genau diesen Child gebundene Installations-ID:

```powershell
.\Tools\Invoke-WindowsServer2003LegacyActivation.ps1 `
    -VmName '<Slot>' `
    -ChildVhdPath '<Lab1_Data>\HyperV\Slots\<Slot>\os.vhdx' `
    -PromptForAdministratorCredential `
    -ActivationMode PrepareOffline
```

Die ausgegebene `InstallationId` wird im Portal eingegeben. Installation-ID,
Portal-Bestätigung und Child müssen aus demselben Aktivierungsvorgang stammen.
Die erhaltene Bestätigungs-ID wird in
Phase 2 geschützt abgefragt und weder protokolliert noch persistiert:

```powershell
.\Tools\Invoke-WindowsServer2003LegacyActivation.ps1 `
    -VmName '<Slot>' `
    -ChildVhdPath '<Lab1_Data>\HyperV\Slots\<Slot>\os.vhdx' `
    -PromptForAdministratorCredential `
    -ActivationMode CompleteOffline `
    -PromptForOfflineConfirmationId
```

Phase 2 ruft `Win32_WindowsProductActivation.ActivateOffline()` auf und gilt
nur bei `ActivationRequired=0` als erfolgreich. Microsoft beschreibt das
aktuelle Portal allgemein für permanente Retail-, OEM- und Volume-Lizenzen;
die Annahme dieser historischen Evaluation ist noch nicht nativ nachgewiesen.
Lehnt Microsoft die Evaluation im Portal ab, ist ein zum Lizenzkanal passendes, rechtmäßig
bezogenes Volume-License-Medium die reproduzierbare Alternative. Ein VLK wird
nicht in die Evaluation-ISO eingesetzt: Medium, Edition, Sprache und Kanal
müssen übereinstimmen. Das Lab implementiert weder Grace-Period-Reset noch
Zeit-, Snapshot- oder WPA-Manipulation.

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
