# Windows-Server-Baseline aus ISO mit Hyper-V erstellen

| Merkmal | Wert |
|---|---|
| Einstieg | `Invoke-SqlServerLab.ps1 -Action Image` |
| Quelle | kanonischer externer Media Root |
| Referenz | Windows Server 2025 Evaluation, English (United States), x64 |
| Build | Generation 2, Secure Boot, isoliert ohne Netzwerkadapter |
| Fortsetzung | persistenter Build-State und PowerShell Direct |

## 1. Voraussetzungen

- Windows-Host mit aktivem Hyper-V und lokalen Administratorrechten;
- PowerShell 7.2 oder neuer;
- Repository-Checkout;
- initialisierter externer Media Root;
- genau eine Windows-Server-ISO im Zielordner.

Die Medienstruktur wird unter
[Externer Media Root](MEDIA_ROOT_LAYOUT.md) beschrieben. Offizielle Quelle für
die Referenz-ISO ist das
[Microsoft Evaluation Center – Windows Server 2025](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025).

Beispiel:

```text
D:\Lab_Base\WindowsServer\2025\Eval\ISO\<Originaldateiname>.iso
```

## 2. Image-Menü starten

Windows-OS-Baselines werden im Menü unter `e` → **Windows-OS-Baselines
verwalten** erstellt. Der Build selbst bleibt ein bewusster administrativer
Schritt, weil Windows einmal installiert und generalisiert werden muss. Die
veröffentlichte `OS_SEALED`-Baseline ist danach jedoch der Standard für
schnelle, reine Windows-Klone. Für ein SQL-Prepared-Image ist weiterhin der
frische Windows+SQL-Pfad im Hauptmenü vorgesehen.

```powershell
Set-Location D:\r\pu\SQL_Server_Lab

.\Invoke-SqlServerLab.ps1 -Action Image
```

Alternativ im Hauptmenü `i` wählen.

Das Image-Untermenü bietet:

1. neuen Builder aus dem Media Root vorbereiten;
2. Build-Status anzeigen;
3. Builder starten und VMConnect öffnen;
4. installiertes Windows über PowerShell Direct generalisieren;
5. generalisierte VHDX immutable in der Registry veröffentlichen;
6. unfertige Builder-Ressourcen scopegebunden aufräumen.

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
- Generation-2-VM;
- Secure Boot mit Microsoft-Windows-Template;
- deaktivierte automatische Hyper-V-Checkpoints;
- ISO als erstes Bootgerät;
- keinen Netzwerkadapter.

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

Nach der Veröffentlichung im Hyper-V-Hauptmenü **Neue Hyper-V-Umgebung aus
Windows- oder SQL-Vorlage erstellen** wählen. Die Auswahl unterscheidet
sichtbar:

- **Windows-OS-Baseline**: Klont eine reine Windows-VM. Die OOBE mit dem
  gewählten Administratorpasswort, Region, Sprache und Tastatur wird in der
  run-eigenen Child-VHDX automatisiert. SQL Server, SQL-WMI, SQL-TCP und
  Connection Strings werden dabei bewusst nicht angefasst.
- **SQL-Prepared-Image**: Klont Windows mit vorbereitetem SQL Server und
  vervollständigt SQL, WMI und TCP/IP für Anwendungen auf dem Host.

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

## 9. Aktuelle Grenze

Diese Welle erstellt eine generalisierte Windows-OS-Baseline. Noch nicht Teil
des freigegebenen End-to-End-Pfads sind:

- unattended Windows-Installation;
- Updates während des Builds;
- SQL Server `CompleteImage` und reguläre SQL-Lab-Runs;
- Netzwerk, IPAM und regulärer Hyper-V-Lab-Run aus einem Manifest;
- automatische SQL-Readiness auf einer realen Baseline.

## 10. Reale Validierung vom 3. August 2026

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
