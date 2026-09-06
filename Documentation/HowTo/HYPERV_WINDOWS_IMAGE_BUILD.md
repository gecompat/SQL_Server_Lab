# Windows-Server-Baseline aus ISO mit Hyper-V erstellen

| Merkmal | Wert |
|---|---|
| Einstieg | `Invoke-SqlServerLab.ps1 -Action Image` |
| Quelle | kanonischer externer Media Root |
| Referenz | Windows Server 2025 Evaluation, English (United States), x64 |
| Build | versionsgerecht Generation 1 oder 2, isoliert ohne Netzwerkadapter |
| Fortsetzung | persistenter Build-State und PowerShell Direct |

Der anschließende Aufbau von drei Windows-SQL-Slots, drei Linux-Zielen und
einem separaten CMS steht im
[End-to-End-Runbook](END_TO_END_TEST_ENVIRONMENT.md).

## 1. Voraussetzungen

- Windows-Host mit aktivem Hyper-V und den erforderlichen Hyper-V-Rechten;
- PowerShell 7.2 oder neuer;
- Repository-Checkout;
- initialisierter externer Media Root;
- ein eindeutiger, englischer und hashgebundener Katalogeintrag für die Zielversion.

Die Medienstruktur wird unter
[Externer Media Root](MEDIA_ROOT_LAYOUT.md) beschrieben. Offizielle Quelle für
die Referenz-ISO ist das
[Microsoft Evaluation Center – Windows Server 2025](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025).

Beispiel:

```text
D:\Lab_Base\WindowsServer\2025\Eval\ISO\<Originaldateiname>.iso
```

## 2. Image-Menü starten

Windows-OS-Baselines werden über die Image-Aktion und dort über `[1]
Windows-OS-Vorlage aus DVD erstellen oder fortsetzen` erstellt. Der Build
selbst bleibt ein bewusster administrativer
Schritt, weil Windows einmal installiert und generalisiert werden muss. Die
veröffentlichte `OS_SEALED`-Baseline ist danach jedoch der Standard für
schnelle, reine Windows-Klone. Für ein SQL-Prepared-Image ist weiterhin der
getrennte Punkt `[3] Neue SQL-Prepared-Vorlage aus DVD erstellen` im selben
Image-Menü vorgesehen.

```powershell
Set-Location <Repository>

.\Invoke-SqlServerLab.ps1 -Action Image
```

Der gleichwertige Hauptmenüpfad lautet `Hyper-V-Infrastruktur` → `Hyper-V
Infrastruktur: OS-Images und ISOs verwalten`.

Im Image-Menü führt `[1]` in das Baseline-Untermenü. Dieses bietet:

1. neuen Builder aus dem Media Root vorbereiten;
2. Build-Status anzeigen;
3. Builder starten und VMConnect öffnen;
4. installiertes Windows über PowerShell Direct generalisieren;
5. generalisierte VHDX immutable in der Registry veröffentlichen;
6. unfertige Builder-Ressourcen scopegebunden aufräumen.

Vor dem UAC-Übergang und erneut vor einer Erstellungsaktion zeigt das Menü den
registrierten `Lab_Data`-Root, die stabile Location, den beobachteten freien
Speicher und die physischen Build-, Image- und Staging-Klassenroots. Dieselbe
read-only Vorschau steht für Skripte zur Verfügung:

```powershell
Get-SqlServerLabHyperVResourcePreview -ResourceClass Build,Image,Staging
```

Der erhöhte Prozess revalidiert die übergebene Location-/Volume-/Root-Evidence;
ein abweichender Prozesskontext wählt keinen anderen Ressourcenroot.

Optional kann ein häufig verwendeter Root für die aktuelle Sitzung vorbelegt
werden. Der Root bleibt im Menü sichtbar und muss dort bestätigt werden:

```powershell
$env:SQL_SERVER_LAB_MEDIA_ROOT = 'D:\Lab_Base'
```

## 3. SHA-256 festschreiben

Vor der ersten Hyper-V-Mutation muss ein Sidecar für genau die ausgewählte ISO
existieren. Fehlt es, zeigt das Menü den vollständigen ISO-Pfad und fragt, ob
der SHA-256 jetzt berechnet werden soll.

Beispielziel:

```text
D:\Lab_Base\Hashes\WindowsServer\2025\Eval\ISO\<Dateiname>.iso.sha256
```

Das Sidecar enthält Digest und relativen Medienpfad. Mehrere ISOs im gleichen
Versionsordner, ein ungültiges Sidecar oder ein Sidecar für einen fremden Pfad
brechen vor der Builder-Erstellung ab. Ein vorhandenes Sidecar wird nicht
überschrieben. Der Builder liest die ISO danach erneut vollständig und prüft
sie gegen den festgeschriebenen Digest sowie die ISO-9660-Signatur.

## 4. Builder erzeugen

Empfohlene erste Auswahl:

| Eingabe | Wert |
|---|---|
| Media Root | `D:\Lab_Base` |
| Windows Server | `2025` |
| Edition | `standard-evaluation` |
| Installationstyp | `desktop-experience` |
| Sprache | `en-US` |

Der aktuelle Operatorpfad erzeugt:

- 80 GB dynamische OS-VHDX;
- 4 GB Startup-RAM;
- 4 virtuelle Prozessoren;
- Windows Server 2008 R2 als Generation-1-VM ohne Secure Boot;
- Windows Server 2012 R2 als Generation-2-VM mit Secure Boot aus, weil der
  aktuelle Hyper-V-DBX-Stand den Bootmanager des archivierten Mediums ablehnt;
- Windows Server 2016 und neuer als Generation-2-VM mit
  Microsoft-Windows-Secure-Boot-Template;
- deaktivierte automatische Hyper-V-Checkpoints;
- ISO als erstes Bootgerät;
- keinen Netzwerkadapter.

### Unbeaufsichtigter Build für 2008 R2 bis 2025

Für Windows Server 2008 R2, 2012 R2, 2016, 2019, 2022 und 2025 steht ein
versionsgerechter Ablauf ohne manuelle Setup-Eingaben zur Verfügung. Der
Aufruf erfolgt in einer
PowerShell-7-Sitzung mit bestätigtem Hyper-V-Capability-Probe, zum Beispiel:

```powershell
.\Tools\New-WindowsServerEvaluationTemplate.ps1 `
    -Version 2008R2,2012R2,2016,2019,2022 `
    -MediaRoot 'D:\Lab1_Base' `
    -ExternalSwitchName 'SQL_LAB_HYPERV_extern_wifi' `
    -Confirm:$false
```

Der Ablauf bindet die englische x64-Evaluation eindeutig an den Katalogpfad,
das SHA-256-Sidecar und die zuvor erzeugte WIM-Evidenz, erzeugt ein
zufälliges nur laufzeitlokales Administratorpasswort, installiert Windows,
prüft Edition und tatsächlichen Evaluationszeitraum, entfernt Antwort-ISO und
Autologon-Daten, aktiviert die Evaluation über einen nur dafür temporär
angehängten externen Netzwerkadapter, entfernt diesen in jedem Fehler- und
Erfolgsfall, führt Sysprep aus und veröffentlicht erst danach `OS_SEALED`.
Anschließend erzeugt er einen neuen isolierten Differencing-Child, schließt
dessen OOBE ab, prüft einen Cold Start sowie die Abwesenheit von SQL Server und
entfernt den Prüflauf wieder. Schlägt dieser Nachweis fehl, wird auch das neu
veröffentlichte, noch unreferenzierte Artifact entfernt. Ein erfolgreicher
Lauf persistiert zusätzlich eine maschinenlesbare
`SqlServerLab.HyperVWindowsTemplateValidation/1.0`-Evidenz unter dem lokalen
StateRoot.
Das Artifact bleibt dabei zunächst als `TemplateValidation=PENDING` für normale
Labs gesperrt. Erst die erfolgreiche Child-Abnahme bindet den SHA-256-Wert der
Evidenz an die Registry-Metadaten und setzt `CHILD_BOOT_VERIFIED`; Fehler
bleiben dadurch auch dann fail-closed, wenn ein Cleanup nicht vollständig
ausgeführt werden konnte.
Ohne `-KeepOnFailure` werden fehlgeschlagene Builder scopegebunden aufgeräumt.
Das Passwort wird weder ausgegeben noch in Build-State oder Artifact-Metadaten
gespeichert; spätere Children erhalten jeweils eigene Credentials.

Windows Server 2008 R2 und 2012 R2 verwenden statt PowerShell Direct einen
temporären externen Adapter und authentifiziertes WMI/DCOM. 2008 R2 erhält
dafür einen emulierten Generation-1-NIC; seine IP-Adresse wird wegen der alten
KVP-Protokollversion direkt und VM-ID-gebunden aus
`Msvm_KvpExchangeComponent/NetworkAddressIPv4` gelesen. Antwortmedien werden
bei Generation 1 ausgeworfen, weil ein laufendes IDE-DVD-Laufwerk nicht
hot-entfernt werden kann.

Das 2008-R2-Evaluationsmedium besitzt laut Microsoft keinen einzugebenden
Product Key. Es verlangt Online-Aktivierung innerhalb von zehn Tagen, bevor
die 180-Tage-Evaluation beginnt. Ist diese historische Aktivierung nicht mehr
erreichbar, veröffentlicht der Builder nur den tatsächlich gemessenen
`OOB_GRACE`-Zeitraum. Ein solches Artifact bleibt bei der standardmäßigen
Mindestrestlaufzeit von 30 Tagen aus der automatischen Auswahl ausgeschlossen;
eine explizite kurzlebige Nutzung muss `MinimumEvaluationDaysRemaining`
entsprechend reduzieren. Es wird weder ein fremder Key eingesetzt noch der
Lizenzzustand als aktiviert ausgegeben.

Cleanup-Plan und Build-State existieren vor der ersten Hyper-V-Mutation. Die
VM wird über BuildId, ScopeId und VHDX-Pfad eindeutig an den Build gebunden.

## 5. Windows manuell installieren

Nach der Builder-Erstellung kann das Menü die VM starten und VMConnect öffnen.
VMConnect wird dabei vor dem VM-Start geöffnet, damit der kurze Hinweis
`Press any key to boot from CD or DVD` sichtbar bleibt. Sobald er erscheint,
sofort eine Taste im VMConnect-Fenster drücken.

1. Passende Evaluation-Ausgabe mit Desktop Experience auswählen.
2. Benutzerdefinierte Installation auf die einzige leere OS-Disk starten.
3. Installation und ersten Start vollständig abschließen.
4. Lokales Administrator-Passwort setzen und außerhalb des Lab-State sicher
   verwahren.
5. Einmal als lokaler Administrator anmelden und prüfen, dass Windows
   vollständig gestartet ist.

Der Builder besitzt absichtlich keinen Netzwerkadapter. Dadurch gibt es in
dieser ersten realen Baseline-Welle weder Internetzugriff noch LAN-Exposition.
Updates und SQL Server sind noch nicht Bestandteil dieser OS-Baseline.

Der persistente Zustand lautet während dieses Abschnitts
`MANUAL_ACTION_REQUIRED`. VM, VHDX und State bleiben über einen Abbruch der
PowerShell-Sitzung hinweg erhalten.

Das Gastpasswort darf frei gewählt werden, muss aber die Kennwortrichtlinie von
Windows Server erfüllen. Es wird für den PowerShell-Direct-Nachweis und Sysprep
noch einmal benötigt und muss deshalb bis zur erfolgreichen Veröffentlichung
bekannt bleiben. Das Repository speichert es weder im Build-State noch in
Evidenzdateien oder VM-Notizen.

## 6. Generalisieren

Im Untermenü **Windows-OS-Baselines** den Punkt **Installiertes Windows generalisieren** auswählen und die lokalen Gast-Administrator-Credentials
eingeben. Credentials werden ausschließlich für PowerShell Direct verwendet
und nicht persistiert.

Vor Sysprep liest die Runtime Produktname, EditionID, Windows-Build und den
tatsächlichen Installationstyp technisch aus dem Gast. Eine Abweichung zwischen
gewähltem `desktop-experience` und installiertem `core` wird nicht still
veröffentlicht: Das Menü zeigt sie an und verlangt eine ausdrückliche
Bestätigung, bevor die Build-Metadaten angepasst werden.

Die Runtime führt aus:

```text
Sysprep.exe /generalize /oobe /mode:vm /quit /quiet
```

Danach werden Microsoft-ImageState, Build-/Scope-Challenge und der geordnete
Gast-Shutdown geprüft. Erfolgreiche technische Evidenz führt zu
`RESUME_PENDING`.

## 7. Immutable Baseline veröffentlichen

Im Untermenü **Windows-OS-Baselines** den Punkt **Windows-Image veröffentlichen** wählen. Für Evaluation-Medien muss das Ablaufdatum
angegeben werden. Der vorgeschlagene Wert von 180 Tagen ist zu prüfen und bei
Bedarf an den tatsächlichen Installations-/Aktivierungszeitpunkt anzupassen.

Vor der Publikation werden geprüft:

- VM ist ausgeschaltet;
- keine Checkpoints sind vorhanden;
- VM- und VHDX-Identität stimmen mit BuildId und ScopeId überein;
- Generalisierungsevidenz und SHA-256 sind unverändert;
- VHDX liegt innerhalb des buildlokalen Ressourcenpfads.

Erst danach wird die VHDX read-only, inhaltsadressiert und als `OS_SEALED` in
die lokale Hyper-V-Image-Registry übernommen. Kopie, Metadaten, Artifact-ID und
SHA-256 müssen vollständig verifiziert sein, bevor die Builder-VM und ihre
buildlokale VHDX werden anschließend über den Cleanup-Plan entfernt; das
Registry-Artefakt bleibt erhalten.

Automatische Hyper-V-Checkpoints sind für neue Builder deaktiviert. Bei einem
älteren oder manuell veränderten Builder bricht die Publikation ab, solange ein
Checkpoint vorhanden ist. Die AVHDX darf nicht manuell gelöscht werden; der
Checkpoint muss bei ausgeschalteter VM über Hyper-V entfernt und die
Zusammenführung in die Basis-VHDX abgewartet werden.

## 8. Reine Windows-VM aus einer OS-Baseline bereitstellen

Nach der Veröffentlichung wieder `-Action Image` öffnen und `[2]
Betriebssystem-Slot aus Windows-OS-Vorlage erstellen` wählen. Dieser Pfad
wählt ausschließlich eine Windows-OS-Baseline:

- **Windows-OS-Baseline**: Klont eine reine Windows-VM. Die OOBE mit dem
  gewählten Administratorpasswort, Region, Sprache und Tastatur wird in der
  run-eigenen Child-VHDX automatisiert. SQL Server, SQL-WMI, SQL-TCP und
  Connection Strings werden dabei bewusst nicht angefasst.

SQL-Prepared-Images besitzen den getrennten Punkt `[3]` und werden unter
[Hyper-V SQL-Prepared-Image](HYPERV_SQL_PREPARED_IMAGE.md) beschrieben.

Die Parent-VHDX bleibt in beiden Fällen unveränderlich. Jeder Klon besitzt
eine eigene differenzierende Child-VHDX und kann ohne Einfluss auf die
Baseline oder andere Windows-Labs entfernt werden. Eine vorhandene,
ausgeschaltete Windows-VM kann alternativ ebenfalls als geschützte, eigene
Arbeitskopie als Klonquelle verwendet werden.

### Reale Cold-Path-Abnahme einer OS-Baseline

Für einen reproduzierbaren Nachweis außerhalb des Menüs steht ein eigener
Integration-Runner bereit. Die Artifact-ID kann im Image-Menü beim Status der
Windows-OS-Baselines abgelesen werden. Der Aufruf muss in einer erhöhten
PowerShell-7-Sitzung auf dem Hyper-V-Host erfolgen:

```powershell
$password = Read-Host 'Gast-Administratorpasswort' -AsSecureString
.\Tests\Integration\Invoke-HyperVWindowsBaselineAcceptanceRun.ps1 `
    -ArtifactId 'hyperv-os-sealed-<sha256>' `
    -AdministratorPassword $password
```

Der Runner erstellt einen frischen differenzierenden Klon, führt die OOBE aus,
prüft die regionale Konfiguration, stoppt und startet die VM über Reconcile,
wartet erneut auf PowerShell Direct und bestätigt, dass keine SQL-Instanz in
der reinen OS-Baseline enthalten ist. Bei Erfolg sowie standardmäßig auch bei
Fehlern werden alle run-lokalen Ressourcen entfernt. Nur `-KeepOnFailure`
behält einen fehlgeschlagenen Run bewusst zur Diagnose. Die immutable
Parent-VHDX wird nicht verändert und nach dem Cleanup erneut verifiziert.

## 9. Status und Recovery

Build-State liegt standardmäßig unter:

```text
%LOCALAPPDATA%\SqlServerLab\image-builds\hyperv\<BuildId>
```

Der State enthält keine ISO-Hostpfade im portablen `build-state.json` und keine
Credentials. Der konkrete lokale ISO-Pfad liegt getrennt im lokalen
Build-Artefakt.

Bei einem Fehler:

1. Image-Menü erneut öffnen;
2. Status anzeigen;
3. denselben Build fortsetzen;
4. nur wenn der Build verworfen werden soll, den Punkt **Unfertigen Windows-Builder aufräumen** zum scopegebundenen
   Cleanup verwenden.

Der Cleanup bietet neben einer einzelnen Nummer auch die Eingabe ALL. Diese Auswahl
entfernt alle angezeigten unfertigen Windows-Builder samt VMs und buildlokalen
VHDX, verlangt eine zweite Gesamtbestätigung und zeigt den Fortschritt. Bereits
als OS_SEALED veröffentlichte Images sind davon ausgeschlossen. Ein erfolgreicher
Cleanup wird als CLEANED_UP markiert und nicht erneut als offener Builder
angeboten.

Ein manuelles Löschen von VM, VHDX oder Build-State kann die gebundene
Recovery-Information zerstören und ist nicht der normale Ablauf.

## 10. Aktuelle Grenze

Dieser Ablauf erstellt eine generalisierte Windows-OS-Baseline. Er installiert
bewusst noch keinen SQL Server. Der nachgelagerte freigegebene Slot- und
Testgruppenpfad ist im End-to-End-Runbook beschrieben. Offene Grenzen der
Baseline-Erstellung sind:

- unattended Windows-Installation;
- Updates während des Builds;
- der allgemeine deklarative Hyper-V-SQL-Runtimepfad über alle
  Manifestkombinationen;
- automatische Artifact-Refresh-/Rebuild-Aktionen.

PowerShell Direct setzt in diesem Vertrag einen Windows-Server-2016-oder-neuer-
Gast voraus. Windows Server 2008 R2 und 2012 R2 verwenden den getrennten,
nativ bestandenen Legacy-WMI-Sysprep- und Child-Nachweis. Der
Gaststeuerungstyp bleibt als `platform.guestControl` im Registry-Artifact
erhalten. Der überprüfte Stand jeder
Version steht in der
[Windows-Server-Vorlagenmatrix](../Quality/WINDOWS_SERVER_TEMPLATE_VALIDATION_MATRIX.md).

## 11. Reale Validierung vom 3. August 2026

Auf dem Self-hosted Hyper-V-Host `KEY18` wurden zwei reale Medienpfade geprüft:

- Windows Server 2025 Standard Evaluation wurde aus der bereitgestellten ISO
  als Server Core installiert. PowerShell Direct erkannte Produkt, Edition,
  Build `26100` und Installationstyp, anschließend erreichte Sysprep den
  Microsoft-State `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE` und die VM fuhr
  geordnet herunter.
- Die bereitgestellte Windows Server 2025 Datacenter Evaluation VHDX wurde mit
  SHA-256 `2d175924c8e647969a82e36f931b22397108bd94a030e0e947b7e66e47e0be9a`
  immutable importiert. Eine isolierte Generation-2-Differencing-VM bootete
  daraus mit Hyper-V-Heartbeat `OK`, ohne Netzwerk, Checkpoint oder verbleibende
  Testressourcen.

Der ISO-Lauf deckte dabei einen Transaktionsfehler im Evaluation-Metadatum auf;
dieser konkrete Build wurde korrekt als `FAILED` erhalten. Der korrigierte
Publikationspfad wird durch Registry-, Builder- und Native-Lifecycle-Tests
abgesichert. Ein vollständiger wiederholbarer ISO-Unattended-Build und der
reale SQL-Server-Gastnachweis bleiben offen. Der inzwischen implementierte
SQL-`PrepareImage`-Builder ist unter
[Hyper-V SQL-Prepared-Image](HYPERV_SQL_PREPARED_IMAGE.md) beschrieben.

Die Grenzen werden zentral unter
[Bekannte Einschränkungen](../Quality/KNOWN_LIMITATIONS.md) geführt.
