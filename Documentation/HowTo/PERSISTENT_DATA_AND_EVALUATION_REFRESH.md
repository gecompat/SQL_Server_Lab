# Persistente Daten und Evaluation-Refresh

| Ebene | Beispiel | Lebensdauer |
|---|---|---|
| Media Root | `D:\Lab_Base` | Installationsquellen |
| Data Root | `D:\Lab_Data` | Datenbank-Backups, Metadaten und versionsgebundene Daten |
| State Root | `%LOCALAPPDATA%\SqlServerLab` | Runs, Image-Registry, Receipts |
| Git-Checkout | `D:\r\pu\SQL_Server_Lab` | Quellcode und Dokumentation |

## 1. Zentralen Data Root erzeugen

Der Data Root muss ausdrücklich angegeben werden und außerhalb des Repository
liegen:

```powershell
.\Tools\Initialize-SqlServerLabDataRoot.ps1 `
    -RootPath 'D:\Lab_Data' `
    -LabId 'training'

$env:SQL_SERVER_LAB_DATA_ROOT = 'D:\Lab_Data'
```

Das Skript ist idempotent und erzeugt lokale READMEs. Bereits vorhandene,
abweichende READMEs werden nicht überschrieben.

```text
D:\Lab_Data\
├── Backups\Verified
├── Catalog
├── Exports
└── Labs\training\
    ├── Backups\Full
    ├── Backups\Differential
    ├── Backups\Log
    ├── Manifests
    ├── Transfer
    └── Versions\
        ├── 2019\Data, Log, TempDb
        ├── 2022\Data, Log, TempDb
        └── 2025\Data, Log, TempDb
```

## 2. Warum Backups die Übergabeebene sind

MDF/LDF-Dateien sind nicht versionsneutral. Wird eine Datenbank durch eine
neuere SQL-Hauptversion aktualisiert, kann sie nicht einfach wieder an eine
ältere Version angehängt werden. Deshalb gelten:

- Full-Backups sind die kanonische Übergabe zwischen alter und neuer VM;
- Restore ist in dieselbe oder eine unterstützte neuere SQL-Version erlaubt;
- jeder SQL-Hauptversion gehört ein eigener Data-/Log-Bereich;
- TempDb wird immer neu erzeugt und nie migriert;
- Rückkehr zu einer älteren SQL-Version benötigt ein dort erzeugtes kompatibles
  Backup oder einen logischen Export.

## 3. Geplanter sicherer Refresh

Mindestens 30 Tage vor Ablauf:

1. Full-Backup jeder Anwendungsdatenbank in `Backups\Full` erstellen;
2. `RESTORE VERIFYONLY` ausführen und SHA-256 erfassen;
3. neue OS-/SQL-Images aus aktuellen Originalmedien bauen;
4. neue VM parallel erstellen und SQL konfigurieren;
5. Backups restaurieren;
6. Datenbankstatus und Anwendungstest prüfen;
7. alte VM erst nach erfolgreicher Abnahme entfernen.

Das vermeidet eine In-place-Verlängerung abgelaufener Evaluationen und erlaubt
einen jederzeit reproduzierbaren Neuaufbau.

## 4. Sicherheits- und Cleanup-Grenzen

Der Data Root wird nicht vom normalen Run-Cleanup gelöscht. Löschoperationen
müssen später eine eigene Daten-Root-Bestätigung und die stabile `LabId`
verlangen. Credentials, PATs, Lizenzschlüssel, Zertifikat-Private-Keys und
Encryption-Key-Backups gehören nicht unverschlüsselt in diesen Root.

Bei TDE oder verschlüsselten Backups müssen Zertifikat und Private Key getrennt,
verschlüsselt und vor dem Entfernen der alten Instanz testweise restauriert
werden.

## 5. Gemeinsame Backup-Bibliothek und private Arbeitsbereiche

Die heruntergeladenen Testdaten liegen zentral in der sichtbaren Testdaten-
Bibliothek, standardmäßig unter `<MediaRoot>\Testdaten\Sammlungen`. Sie ist die
gemeinsame, unveränderliche Quelle für alle katalogisierten `.bak`-Dateien,
ZIP-/7z-Archive und Skripte: Ein Download wird nur einmal geprüft und danach
für weitere Labs wiederverwendet.

Davon getrennt ist der **Backup-Arbeitsbereich** einer Umgebung. Er ist
schreibbar und gehört genau einem Lab. Damit kann kein paralleler SQL-Dienst
eine Sicherung einer anderen Umgebung überschreiben:

| Provider | gemeinsame Quelle | schreibbarer Arbeitsbereich |
|---|---|---|
| Docker / Podman | Testdaten-Bibliothek auf dem Host; das Framework kopiert die gewählte, verifizierte Quelle vor dem Restore | `<DataRoot>\Labs\...\backups` → `/var/opt/mssql/backup` |
| Hyper-V | Testdaten-Bibliothek auf dem Host. Für einen automatisierten Restore muss die gewählte Datei gezielt in den Gast-Arbeitsbereich übertragen werden; ein ungesicherter Host-Mount findet nicht statt. | eigene Daten-VHDX → `S:\SQLData\Backups` |

Ein einziger, gleichzeitig beschreibbarer Ordner für alle VMs ist absichtlich
kein Default. Hyper-V kann einen Hostordner nicht wie Docker als Laufwerk
einbinden; ein SMB-Share würde zusätzliche Host-Firewall-, Dienstkonto- und
Berechtigungsregeln benötigen. Für einen echten Live-Share muss dieser
explizit und mit passenden Sicherheitsvorgaben eingerichtet werden. Die
Standardlösung bleibt deshalb: gemeinsame geprüfte **Quelle**, isolierter
schreibbarer **Arbeitsbereich**. Die gezielte Übertragung aus der Bibliothek in
einen Hyper-V-Gast ist als nächste Erweiterung vorgesehen; bis dahin ist die
Bibliothek nicht als direkt im Gast sichtbarer Ordner zu verstehen.

## 6. Optionale Runtime-Anbindung

Der Data Root wird in der Workflow-Oberfläche unter **Medienquellen** einmalig
als lokaler Standard gespeichert. Beim Erstellen einer neuen Docker- oder
Podman-Umgebung aktiviert die Option **Daten dauerhaft im konfigurierten Data
Root speichern** ein stabil benanntes Runtime-Volume fuer `/var/opt/mssql`
und bindet dessen Backup-Verzeichnis in den Data Root ein. Das ist bewusst:
Ein direkter NTFS-Bind-Mount auf `/var/opt/mssql` kann mit SQL Server 2025 in
Docker Desktop unter Windows abstuerzen. Das Runtime-Volume und der Data Root
bleiben beim Entfernen der Umgebung erhalten; die Verknuepfung ist im
Run-Metadatum sichtbar.

Für reguläre Hyper-V-Umgebungen kann beim Erstellen oder nachträglich im
ausgeschalteten Zustand eine langlebige Daten-VHDX angehängt werden. Nach dem
Start initialisiert die UI sie mit einer bestätigten Gastanmeldung unter einem
freien Gastbuchstaben, bevorzugt als `S:\SQLData`; `D:` bleibt bewusst dem oft
vorhandenen DVD-Laufwerk vorbehalten. Auch diese VHDX liegt außerhalb des Run-State und wird nicht vom
normalen Cleanup entfernt.

Der interne Wiederverwendungs-Core kann eine bereits katalogisierte Hyper-V-
Daten-VHDX nach belegtem Clean-Detach per stabiler Storage-ID auswählen,
quellenunverändert in eine eigenständige VHDX klonen, an eine ausgeschaltete
scopegebundene VM reattachen und wieder freigeben. Dabei werden DiskIdentifier,
Hostbindung, Attachments, Checkpoints, SQL-Major-Version und freier Gastpfad
vor der Mutation geprüft. Das bloße Vorhandensein von MDF/NDF/LDF-Dateien
schaltet keine Datenbank online; Restore beziehungsweise Attach bleibt eine
eigene explizite Aktion. Der Flow ist noch nicht als öffentlicher CLI-/GUI-
Befehl verfügbar.

Bereits bestehende Container lassen sich technisch nicht um einen Mount
erweitern. Eine Übernahme ihrer bestehenden Daten erfordert daher einen
kontrollierten Neuaufbau per Backup/Restore; sie wird nicht stillschweigend
durch einen physischen Dateikopier-Versuch ausgeführt. Automatisches SQL
`BACKUP`/`RESTORE VERIFYONLY`, SHA-256-Receipts und TDE-Schlüsseltransfer
bleiben separate weitere Schritte.
