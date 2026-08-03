# Persistente Daten und Evaluation-Refresh

| Ebene | Beispiel | Lebensdauer |
|---|---|---|
| Media Root | `D:\Lab_Base` | Installationsquellen |
| Data Root | `D:\Lab_Data` | Datenbank-Backups und versionsgebundene Daten |
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

## 5. Implementierungsstand

Die zentrale Struktur, Idempotenz, lokale Anleitung und versionsgetrennte
Ablage sind implementiert und statisch getestet. Automatisches SQL
`BACKUP`/`RESTORE VERIFYONLY`, SHA-256-Receipts, TDE-Schlüsseltransfer und das
Anbinden persistenter VHDX an reguläre Hyper-V-Runs folgen mit dem
`CompleteImage`-/Daten-Lifecycle. Bis dahin ist der obige Backup-/Restore-Ablauf
ein verbindlicher Operatorprozess, kein bereits vollständig automatisierter
Runtimepfad.
