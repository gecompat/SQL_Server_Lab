# SQL-Version-Upgrade-Referenz: 2022 nach 2025

Status: `implemented`, native Docker-/Podman-Abnahme `NOT_EXECUTED`.

Der feste Integrationstest erzeugt zwei neue eigene Runs auf demselben explizit
gewählten Containerprovider. Er prüft einen Datenbanktransfer über die
öffentlichen Befehle `Backup-SqlServerLabDatabase` und
`Restore-SqlServerLabDatabase -BackupSetId`. Die allgemeine Backup-Bibliothek
unterstützt diesen Versionswechsel; die separate SQL-2025-Grenze des portablen
Containertransfers wird nicht erweitert. Ein allgemeiner Szenarioexecutor,
beliebige Quellen und ein Instanzupgrade gehören nicht zu dieser Referenz.

## Fachlicher Ablauf

1. Eigene SQL-2022-Quelle (live Major 16), neue synthetische Datenbank und
   Compatibility Level 160; zwei Gruppen und drei Konten mit festen Beträgen.
2. Exakte Zeilen und Gruppen, Join-Aggregate, Transaktionsrollback sowie
   CHECK-/Foreign-Key-/Primary-Key-Verletzungen prüfen; `DBCC CHECKDB` ausführen.
3. Öffentliches Full-Backup registrieren. Die Bibliothek erzeugt `CHECKSUM`,
   `RESTORE VERIFYONLY` und SHA-256; die Referenz liest die registrierte Auswahl
   erneut mit Hashprüfung und prüft Herkunft, Verifikationsflags und den
   Ausschluss von TDE/FILESTREAM.
4. Neues getrenntes SQL-2025-Ziel (live Major 17) erstellen. Den registrierten
   `BackupSetId` in eine neue Zieldatenbank wiederherstellen. Direkt danach muss
   Compatibility Level 160 erhalten sein; dieselbe Workload und Integrität prüfen.
5. Als gesonderte Aktion `ALTER DATABASE ... SET COMPATIBILITY_LEVEL=170`
   ausführen und Workload/Integrität erneut prüfen. Die Quelle bleibt Major 16,
   Compatibility Level 160 und enthält weiterhin exakt ihre synthetischen Daten.

Die Erhaltung des bisherigen Compatibility Levels beim Restore und der separate
Wechsel entsprechen dem [Microsoft-Vertrag für Datenbank-Upgrades](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/restore-a-database-backup-under-the-simple-recovery-model-transact-sql?view=sql-server-ver17).
Messwerte sind beobachtete Dauern für Quellprüfung, öffentlichen Restore,
beide Zielphasen und abschließende Quellprüfung. Es gibt keine erfundene
Leistungsschwelle und keinen allgemeinen Performance-Paritätsnachweis.

## Ausführung und Isolation

```powershell
.\Tests\Integration\Invoke-SqlVersionUpgradeAcceptance.ps1 -Provider docker
.\Tests\Integration\Invoke-SqlVersionUpgradeAcceptance.ps1 -Provider podman
```

Beide Befehle werden getrennt und sequenziell nach der jeweiligen Readiness
abgenommen. Erforderlich sind die katalogisierten SQL-2022-/SQL-2025-Images und
Kapazität für zwei kompakte eigene Runs. Der Runner initialisiert Hostwerkzeuge
nur pro Prozess; er startet keine Podman-Machine und ändert keine Hostkonfiguration.
Vorhandene Runs, fremde Datenbanken und beliebige Backupquellen sind keine Parameter.

Der Parent hält `SQL_Server_Lab_Runtime_Smoke` (unter Windows im globalen
Namespace); der bestehende CI-Workflow übergibt seinen bereits gehaltenen Lock
mit `-RuntimeMutexAlreadyHeld`. Vor Arrange werden beide eigenen Operations-IDs
in einem zugriffsbeschränkten temporären Root persistiert. Ein eigener StateRoot
und `Lab_Data` isolieren Run-State, Secrets und Backupkatalog. Der Child persistiert
zusätzlich die aktuelle Runtime-ID vor dem ersten `New`; Intent und Run-Bindungen
verwenden den vorhandenen atomaren JSON-Writer. Er bindet jeden Run an
seine eigene Operation, Run-/Scope-/Instance-Labels, exakte Container-ID,
Loopback-Port und ausschließlich eigenes, nicht geteiltes MSSQL-Volume.
SQL-Aufrufe prüfen die Live-Bindung erneut.

Arrange läuft in einem verborgenen Child mit standardmäßig 900 Sekunden
Gesamtbudget (`-TimeoutSeconds`, maximal 1800). Eigene SQL-Probes verwenden
`SqlCredential`, 15 Sekunden Connection- und 45 Sekunden Command-Timeout;
Connection, Reader, Command und SecureString werden auch bei Fehlern geschlossen.
Die öffentlichen Backup-/Restore-Helfer bleiben unverändert und liegen ebenfalls
innerhalb des Child-Gesamtbudgets.

Nach bestätigtem Child-Ende startet der Parent unabhängig ein begrenztes
Cleanup-Child (600 Sekunden). Es sucht beide Operationen auch nach verlorener
`New`-Antwort im eigenen State, versucht Ziel und Quelle unabhängig voneinander
und prüft öffentlichen Remove-Erfolg sowie Label- und exakte Ressourcenresiduen.
Geänderte Runtime-/Operations-/Providerbindung blockiert die betreffende Mutation.
Unbestätigtes Prozessende blockiert Cleanup statt mit dem laufenden Child zu
konkurrieren. Timeouts und Cleanupfehler ergeben stets `FAILED`; Recovery-State
bleibt erhalten. Ein hart beendeter Parent kann kein automatisches Cleanup
zusichern; persistierte Operationen und State ermöglichen die gezielte Recovery.

Rohstreams, synthetische Backups und Katalog-/SQL-Receipts bleiben ausschließlich
im geschützten lokalen Root zur Diagnose erhalten; der Test löscht nach seinem
Runtime-Cleanup keine Evidence-Wurzel. GitHub erhält nur geschlossene
`SQL_UPGRADE`-Status-/Reason-Codes. Der Test veröffentlicht keine Rohlogs,
Credentials, Runtime-IDs oder Hostpfade.

## Nachweise und Grenzen

`Invoke-SqlVersionUpgradeScenarioChecks.ps1` führt den wirklichen Kontrollfluss
mit synthetischen Transport-/Providergrenzen aus: zwei Versionen, fremde Labels,
Runtimewechsel, falsche Backup-Evidence, verlorenes Source-/Target-New,
inkompatibles Restore, Inhalts-/Aggregat-/Transaktions-/Integritätsfehler und
unabhängiges Cleanup einschließlich erhaltener Fehler-State-Dateien.
`Invoke-SqlVersionUpgradeSupervisorChecks.ps1` startet echte eigene Kindprozesse
für Erfolg, Fehler, harten Teilabbruch, Timeout und Cancellation; sie prüft
bestätigte Terminierung, private Rohstreams und fehlgeschlagenes Output-Drain.
Offline-Checks führen kein SQL aus und ersetzen keinen nativen Providernachweis.

Docker und Podman bleiben bis zur getrennten Abnahme `NOT_EXECUTED`.
Hyper-V, weitere Versionspaare, Serverobjektmigration, TDE/FILESTREAM,
Produktionsdaten, Query-Store-/Anwendungsregressionen, beliebige Workloads und eine Performancefreigabe bleiben
außerhalb dieses festen Tests. Die neue Einzelpfadklassifikation wählt nur
Docker/Podman. Änderungen am gemeinsamen Selektor beziehungsweise an der
CI-Infrastruktur wählen weiterhin die bestehende volle Pflichtmatrix.
