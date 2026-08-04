# SQL Server 2019, 2022 und 2025 aus einer gemeinsamen Windows-Baseline

| Merkmal | Wert |
|---|---|
| Betriebssystem | Windows Server 2025 Core oder Desktop Experience |
| Einstieg | `Invoke-SqlServerLab.ps1 -Action Image` |
| Ziel | ein immutable `SQL_PREPARED_SEALED`-Artifact je SQL-Hauptversion |
| SQL-Features | Database Engine, Full-Text, Replication |
| Netzwerk während Build | internes `SQL_LAB_HYPERV`, kein Egress |

## 1. Zuerst den passenden Weg wählen

Die Einträge `7` bis `16` enthalten **zwei getrennte Workflows**. Sie werden
nicht hintereinander auf demselben Builder ausgeführt.

| Ziel | Menüfolge | Ergebnis |
|---|---|---|
| Wiederverwendbares SQL-Grundimage | `7 → 9 → 10 → 11` | immutable `SQL_PREPARED_SEALED`; SQL ist nur mit `PrepareImage` vorbereitet |
| Laufende Test- und Abnahme-VM | `7 → 13 → 14` | run-lokale VM mit vollständig installierter SQL-Instanz |
| Laufende Abnahme-VM, falls OOBE manuell erledigt wurde | `7 → 9 → 16 → 14` | wie der vorherige Pfad, nur mit manuell abgeschlossenem OOBE |

`13` ist somit **keine** Vorbereitung für `10`: Aktion 13 installiert eine
vollständige, konkrete SQL-Instanz für Tests. Aktion 10 installiert dagegen
`PrepareImage` und generalisiert Windows erneut, damit daraus ein portables
Grundimage entstehen kann. Nach `13` wird daher nicht `10` ausgeführt.

Auch beim Prepared-Image wird Windows nicht neu installiert: Die von Aktion 7
erzeugte VM ist eine Differencing-VM auf der vorhandenen `OS_SEALED`-VHDX. Die
einmalige OOBE erzeugt lediglich die neue Gastidentität und das lokale
Administratorpasswort.

## 2. Warum eine Windows-Baseline genügt

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

## 3. Medien im zentralen Media Root

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

## 4. Builder über das Menü erzeugen

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
deaktivierten automatischen Checkpoints und dem internen `SQL_LAB_HYPERV`-
Switch. Die SQL-ISO wird als DVD eingebunden. Der OS-Parent bleibt unverändert
und read-only; ein externer Netzwerkzugang wird nicht bereitgestellt.

## 5. OOBE für den Abnahme-VM-Pfad: automatisch oder kontrollierter Fallback

Ein generalisiertes Windows-Image startet absichtlich in OOBE. Im
**Abnahme-VM-Pfad** kann Aktion 13 den Schritt vollständig automatisieren. Sie erzeugt ein Zufallspasswort,
speichert es nur lokal per Windows-DPAPI, stoppt die VM, schreibt eine
`Unattend.xml` offline in `Windows\Panther` und startet die VM wieder. Der
verifizierte Zielzustand lautet:

- Region und Systemlocale: Deutschland / `de-DE`;
- UI-Sprache: `en-US`;
- Tastatur: Deutsch / `0407:00000407`;
- Zeitzone: `W. Europe Standard Time`;
- Windows-State: `IMAGE_STATE_COMPLETE`.

Das Offline-Einbinden einer VHDX verlangt unter Windows ein erhöhtes Token mit
dem erforderlichen Volume-Recht. Mitgliedschaft in der Gruppe
`Hyper-V-Administratoren` allein genügt dafür nicht. Läuft der Remote Runner
nicht erhöht, meldet die Runtime
`HYPERV_SQL_OOBE_OFFLINE_MOUNT_REQUIRES_ELEVATED_RUNNER`, ohne den Parent zu
verändern. Dann gilt der kontrollierte Fallback:

1. VMConnect öffnen;
2. Germany, English (United States) und German auswählen;
3. lokales Administratorpasswort festlegen und einmal anmelden;
4. im Image-Menü Aktion 16 wählen und das Passwort als SecureString eingeben.

Aktion 16 speichert Gast- und SA-Passwort nur lokal verschlüsselt im
Build-Verzeichnis. Klartext erscheint weder im Build-State noch in Evidenz,
VM-Notizen oder Git. Die Antwortdatei wird nach positivem OOBE-Receipt aus dem
Gast entfernt.

Für den **Prepared-Image-Pfad** ist Aktion 9 der bewusste manuelle OOBE-Schritt:
lokales Administratorpasswort setzen, einmal anmelden und danach Aktion 10
mit genau diesen Zugangsdaten ausführen. Aktion 10 führt die SQL-Installation
ohne weitere VMConnect-Interaktion aus.

Offizielle Referenzen:

- [Mount-VHD](https://learn.microsoft.com/en-us/powershell/module/hyper-v/mount-vhd)
- [Windows-Antwortdateien](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/update-windows-settings-and-scripts-create-your-own-answer-file-sxs)

## 6. SQL vorbereiten und Windows generalisieren

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

## 7. Immutable SQL-Baseline veröffentlichen

Aktion 11 prüft VM-Identität, Auszustand, fehlende Checkpoints und den
buildlokalen VHDX-Pfad. Weil der Arbeitsdatenträger eine Differencing-VHDX ist,
wird die vollständige Kette zuerst mit `Convert-VHD` in eine eigenständige
dynamische VHDX überführt. Erst danach erfolgen SHA-256, Registry-Import und
Metadatenprüfung. VM und lokale Build-VHDX werden erst nach erfolgreichem
Registry-Import entfernt.

Das Ergebnis ist ein `SQL_PREPARED_SEALED`-Artifact. Eine spätere Lab-VM muss
noch SQL `CompleteImage` ausführen und Instanzkonto, Administratoren,
Authentifizierung und Pfade konfigurieren.

## 8. Evaluation und Developer

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

## 9. Direkte Windows-SQL-Abnahmeumgebungen

Neben `PrepareImage` bietet das Menü einen run-lokalen Abnahmepfad:

- Aktion 13: OOBE und vollständiges SQL Setup automatisch ausführen;
- Aktion 16: manuell abgeschlossene OOBE übernehmen und SQL Setup ausführen;
- Aktion 14: Create/Insert/Select, Backup mit `CHECKSUM`, `RESTORE VERIFYONLY`
  und Cleanup testen;
- Aktion 15: Matrix für SQL 2019, 2022 und 2025 anzeigen.

Die drei erwarteten SQL-Major-Versionen sind 15, 16 und 17. Ein System erhält
erst nach Dienst-, Versions- und Systemdatenbankprüfung `SQL_READY_RUN`; erst
der vollständige Datenbank-/Backup-Test führt zu `TESTS_PASSED`.

## 10. Aktueller Nachweisstand

Der Host-Lifecycle, Medienresolver, resumierbare Receipts, Secret-Freiheit,
Flatten-before-import und Menüpfad sind automatisiert getestet. Der reale
`PrepareImage`-Lauf mit den bereitgestellten Microsoft-ISOs und die direkte
SQL-2019/2022/2025-Abnahmematrix sind die nächsten nativen Schritte. Auf einem
nicht erhöhten Runner bleibt der dokumentierte OOBE-Fallback einmalig nötig.
Der feste interne Hyper-V-Hostzugriff ist implementiert; runtimeübergreifende
Netze und kontrollierter Internet-Egress sind nicht Teil dieses Nachweises.
