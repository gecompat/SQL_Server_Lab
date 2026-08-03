# SQL Server 2019, 2022 und 2025 aus einer gemeinsamen Windows-Baseline

| Merkmal | Wert |
|---|---|
| Betriebssystem | Windows Server 2025 Core oder Desktop Experience |
| Einstieg | `Invoke-SqlServerLab.ps1 -Action Image` |
| Ziel | ein immutable `SQL_PREPARED_SEALED`-Artifact je SQL-Hauptversion |
| SQL-Features | Database Engine, Full-Text, Replication |
| Netzwerk während Build | keines |

## 1. Warum eine Windows-Baseline genügt

Die vorhandene Windows-Server-2025-Baseline ist der gemeinsame OS-Parent für
SQL Server 2019, 2022 und 2025. Für jede SQL-Version wird eine eigene
Differencing-VM erzeugt. Das Betriebssystem wird deshalb nicht dreimal manuell
installiert.

Windows Server Core ist dafür gültig. Microsoft unterstützt dort unter anderem
Database Engine, Replication und Full-Text. Die grafische Setup-Oberfläche ist
auf Server Core nicht verfügbar; SQL Setup muss mit `/Q` oder `/QS` ausgeführt
werden. SSMS wird auf einem anderen Rechner installiert und verbindet sich
später remote.

Offizielle Referenzen:

- [SQL Server auf Server Core installieren](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-on-server-core)
- [SQL Server über die Eingabeaufforderung installieren](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt)
- [SQL Server mit SysPrep vorbereiten](https://learn.microsoft.com/en-us/sql/database-engine/install-windows/considerations-for-installing-sql-server-using-sysprep)

## 2. Medien im zentralen Media Root

Beispielroot: `D:\Lab_Base`

```text
D:\Lab_Base\SQL\2019\Eval\ISO\SQLServer2019-x64-ENU.iso
D:\Lab_Base\SQL\2022\Eval\ISO\SQLServer2022-x64-ENU.iso
D:\Lab_Base\SQL\2025\Enterprise\ISO\SQLServer2025-x64-ENU-EntDev.iso
D:\Lab_Base\SQL\2025\Standard\ISO\SQLServer2025-x64-ENU-StdDev.iso
```

Die Struktur wird mit
`Tools\Initialize-SqlServerLabMediaRoot.ps1 -RootPath 'D:\Lab_Base'`
erzeugt. Genau eine ISO darf im ausgewählten Versions-/Editionsordner liegen.
Vor der ersten VM-Mutation bindet ein SHA-256-Sidecar Digest und relativen Pfad.

## 3. Builder über das Menü erzeugen

```powershell
$env:SQL_SERVER_LAB_MEDIA_ROOT = 'D:\Lab_Base'
.\Invoke-SqlServerLab.ps1 -Action Image
```

Im Image-Menü Aktion 7 wählen. Danach:

1. SQL-Version auswählen;
2. Medien-Edition auswählen;
3. vorhandenes `OS_SEALED`-Artifact auswählen;
4. fehlendes SHA-256-Sidecar nach Sichtprüfung erzeugen;
5. Builder bestätigen.

Der Builder erzeugt eine Generation-2-Differencing-VM mit Secure Boot,
deaktivierten automatischen Checkpoints und ohne Netzwerk. Die SQL-ISO wird als
DVD eingebunden. Der OS-Parent bleibt unverändert und read-only.

## 4. Einmaliger OOBE-Schritt

Ein generalisiertes Windows-Image startet absichtlich in OOBE. Deshalb ist je
neuem SQL-Image genau ein kurzer manueller Schritt nötig:

1. VMConnect öffnen;
2. lokales Administratorpasswort festlegen;
3. einmal anmelden;
4. zum Image-Menü zurückkehren.

Das Passwort muss bis zur Veröffentlichung bekannt bleiben. Es wird nur als
PowerShell-Direct-Credential im Arbeitsspeicher verwendet und weder im
Build-State noch in Evidenz, VM-Notizen oder Git gespeichert.

## 5. SQL vorbereiten und Windows generalisieren

Aktion 10 führt ohne weitere Setup-GUI aus:

```text
setup.exe /Q /ACTION=PrepareImage
  /FEATURES=SQLENGINE,FULLTEXT,REPLICATION
  /INSTANCEID=MSSQLSERVER
  /ENU=True
  /IACCEPTSQLSERVERLICENSETERMS
```

Setup-Version, Features und Exitcode werden als bereinigtes Receipt
festgehalten. Exitcode `3010` führt zu `REBOOT_REQUIRED`; nach dem Neustart wird
Aktion 10 erneut gewählt. Anschließend folgt:

```text
Sysprep.exe /generalize /oobe /mode:vm /quit /quiet
```

Nur der Microsoft-State `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE` und ein
beobachteter Gast-Shutdown führen zu `RESUME_PENDING`.

## 6. Immutable SQL-Baseline veröffentlichen

Aktion 11 prüft VM-Identität, Auszustand, fehlende Checkpoints und den
buildlokalen VHDX-Pfad. Weil der Arbeitsdatenträger eine Differencing-VHDX ist,
wird die vollständige Kette zuerst mit `Convert-VHD` in eine eigenständige
dynamische VHDX überführt. Erst danach erfolgen SHA-256, Registry-Import und
Metadatenprüfung. VM und lokale Build-VHDX werden erst nach erfolgreichem
Registry-Import entfernt.

Das Ergebnis ist ein `SQL_PREPARED_SEALED`-Artifact. Eine spätere Lab-VM muss
noch SQL `CompleteImage` ausführen und Instanzkonto, Administratoren,
Authentifizierung und Pfade konfigurieren.

## 7. Evaluation und Developer

Windows- und SQL-Lizenzstatus werden getrennt gespeichert:

- das Ablaufdatum einer Windows-Evaluation wird vom OS-Parent übernommen;
- ein SQL-Evaluation-Image vermerkt, dass seine Evaluation erst bei
  `CompleteImage` beginnt; ein erfundenes Ablaufdatum wird nicht gespeichert;
- Enterprise Developer und Standard Developer sind nicht für Produktion
  freigegeben;
- ein ablaufendes Image wird neu aus Originalmedien gebaut, nicht verlängert
  oder manipuliert.

Datenbanken liegen nicht im austauschbaren Image. Der Refresh- und
Backupvertrag steht unter
[Persistente Daten und Evaluation-Refresh](PERSISTENT_DATA_AND_EVALUATION_REFRESH.md).

## 8. Aktueller Nachweisstand

Der Host-Lifecycle, Medienresolver, resumierbare Receipts, Secret-Freiheit,
Flatten-before-import und Menüpfad sind automatisiert getestet. Der reale
`PrepareImage`-Lauf mit den bereitgestellten Microsoft-ISOs ist als nächster
nativer Schritt vorgesehen und benötigt einmalig den OOBE-/Passwortschritt pro
SQL-Version. `CompleteImage`, automatisches Backup/Restore und produktive
Hyper-V-Netzwerke sind noch nicht Teil dieses Nachweises.
