# Ein-Datenbank-Transfer in einen eigenen Container-Run

`Invoke-SqlServerLabPortableContainerTransfer` überträgt genau eine bereits
`ONLINE/READ_ONLY` geschaltete verwaltete SQL-2025-Linux-Datenbank. Quelle und
neues Ziel verwenden denselben Docker- oder Podman-Provider und dieselbe
Runtime-Scope-Bindung. Der Executor erstellt das Ziel selbst mit generiertem
verwaltetem Kennwort und einem ausschließlich rungebundenen SQL-Named-Volume.
Ein vorhandener Ziel-Run wird nicht übernommen. Die Quelle wird nur gelesen.

Der vorhandene Mehrdatenbank-Executorplan sowie der Medienpreflight für
bestehende Ziele bleiben eigenständige, nicht ausführende Verträge. Der
read-only Vergleich behält `RELATIONAL_CORE/1.0`; dessen Resultat erteilt keine
Transferautorität. Der Executor verwendet ausschließlich dessen Inhaltsbefund.

## Grenzen und Voraussetzungen

- Ein `REUSABLE` Bibliotheksbackup mit kanonischem, reparse-freiem Objektpfad,
  Quellbindung, CHECKSUM-/VERIFYONLY-Evidence, SHA-256 und Größe; maximal
  256 MiB Backupgröße. `HEADERONLY` muss SQL 2025, vollständiges unverschlüsseltes
  Backup, read-only Snapshot und die live gebundene Datenbank-GUID bestätigen.
- Nur die Tabellen-/Typenmenge von `RELATIONAL_CORE/1.0`, maximal 32 Tabellen
  und insgesamt 100000 Zeilen. Die live gelesene Quellinventur wird vor
  Zielerstellung geprüft. Systemdatenbanken, Snapshots, TDE, FILESTREAM,
  Replikationsdatenbanken und unbekannte Backup-Dateitypen sind ausgeschlossen.
- Maximal 16 Datendateien/Logdateien und insgesamt 1 GiB restaurierte
  Dateigröße. Vor Staging und Restore werden zusätzlich 512 MiB freie Reserve
  auf dem Ziel-Dateisystem verlangt. Die Prüfungen reservieren keinen globalen
  Speicherplatz; konkurrierender Verbrauch kann weiterhin zum Fehler führen.
- Der Ziel-Run verwendet das Profil `compact`, eine CPU und 2560 MiB RAM.
  Die bestehende Ressourcenprüfung bleibt aktiv. Port und Runtime-Namen werden
  durch die bestehenden Erstellungsfunktionen vergeben.
- Native Hilfsbefehle sind begrenzt; Kopieren hat 600 Sekunden, RESTORE den
  Parameter `RestoreTimeoutSeconds` (30–900, Standard 600). Der Inhaltsvergleich
  besitzt ein 300-Sekunden-Budget für Tabellen-/Zeileniteration; einzelne
  bestehende SQL-Aufrufe behalten ihre zusätzlichen begrenzten CommandTimeouts.
  Ein Timeout ist kein erfolgreicher Rollback und kein erlaubter Retry.

## Ownership und SQL-Verbindung

Vor jeder wesentlichen Mutation werden Run, Scope, Workflow-Operation,
Provider, RuntimeScopeId, vollständige ContainerId und Volume-Anbindung
überprüft. Das Ziel erlaubt genau ein schreibbares eigenes Named-Volume an
`/var/opt/mssql`, keine Bind-Mounts, übernommenen Stores oder weiteren
Volume-Konsumenten. Run-, Scope- und Instanzlabels müssen übereinstimmen.

SQL-Endpunkte müssen exakt der inspizierten Loopback-Portbindung entsprechen.
Der lokale Journalfingerprint schließt den Endpunkt ein; der Vergleich prüft
die erwarteten Bindungen erneut vor Secretauflösung. Endpunkte und Credentials
erscheinen nicht im öffentlichen Ergebnis. Der lokale Journal enthält nur
benötigte Identitäten, Hashes, Dateizuordnungen und Statuswerte.

Die Payload wird unter einen eindeutigen Operationspfad kopiert, anschließend
im Container erneut gehasht und SQL-seitig geprüft. `FILELISTONLY` bestimmt
alle logischen Dateien und ihre Größen. Jede Datei erhält einen eindeutigen
operationsgebundenen MOVE-Pfad. Vorhandene Zieldateien, Symlinks und vorhandene
Benutzerdatenbanken blockieren. RESTORE verwendet niemals `REPLACE`.

## Journal und Wiederaufnahme

Das atomare Journal liegt unter
`<StateRoot>/portable-container-transfers/<OperationId>.json`; eine exklusive
Dateisperre verhindert parallele Aufrufe derselben Operation. Request,
Bibliotheks-/State-Root und Restorefrist sind über den Requesthash gebunden.
Geänderte Eingaben unter derselben ID werden abgewiesen.

Die Phasen sind `INTENT`, `CREATE_STARTED`, `TARGET_CREATED`, `STAGED`,
`RESTORE_STARTED`, `RESTORED`, `VERIFIED` und `SUCCEEDED`. Das Journal wird vor
Zielerstellung und vor RESTORE geschrieben. Zielerstellung verwendet den
bestehenden Workflow-Operation-Kontext. Fehlt die Rückgabe, darf ausschließlich
ein eindeutig operationseigener, vollständig live verifizierbarer Run für
Cleanup wiedergefunden werden. Unvollständige oder mehrdeutige Erzeugung bleibt
`RECOVERY_REQUIRED`.

Wiederaufnahme eines nicht terminalen Journals versucht ausschließlich
Whole-Run-Cleanup. Sie setzt den Transfer nicht fort und wiederholt RESTORE
niemals. Auch fehlende SQL-Antwort, Timeout oder ein Crash nach RESTORE gelten
nicht als Beweis für eine fehlende Mutation. Es gibt kein datenbankweises DROP.

Cleanup prüft die vollständige Zielbindung und verwendet anschließend
`Remove-SqlServerLab`: zuerst den eigenen Container beenden/entfernen, danach
seine eigenen Volumes. Erfolg benötigt `REMOVED` und eine erreichbare Runtime
mit bestätigter Abwesenheit der exakten Ressourcen sowie der Run-Labels.
Fehlerursache und Cleanupstatus bleiben getrennt. Fehlende Ownership,
unbestätigte Entfernung oder Runtimeprobleme ergeben `RECOVERY_REQUIRED`.

`FAILED_CLEANED` ist ein fehlgeschlagener Transfer mit bestätigtem Cleanup.
`SUCCEEDED` bedeutet erfolgreicher read-only Vergleich und bereinigtes Staging;
der eigene Ziel-Run bleibt absichtlich erhalten. Terminale Wiederholung gibt
den historischen Nachweis ohne neue Mutation zurück; sie behauptet keine neue
Live-Validierung eines inzwischen vom Benutzer veränderten Ziels.

## Prüfung und offene Breite

`Tests/Static/Invoke-PortableContainerTransferExecutorRuntimeChecks.ps1` prüft
offline: Ownership, Endpunktdrift, geteilte/fremde Volumes,
Request-/Lockkollision, Größenlimit, Journalfehler, verlorene Create-/Restore-
Antwort, abweichender Inhalt, Cleanupfehler, Residuen und Resume ohne erneuten
Restore. Die fokussierte Offlineprüfung bestand am 2026-09-20 mit 32 Assertions,
einschließlich realer SqlClient-Builder- und sequenzieller Reader-Characterization.
Der bestehende Vergleichsvertrag wird zusätzlich geprüft.

`Tests/Integration/Invoke-PortableContainerTransferAcceptance.ps1 -Provider docker`
beziehungsweise `-Provider podman` verwendet ausschließlich eigene synthetische
Runs. Es prüft WhatIf, Backup/Restore, read-only MATCH, terminales Replay,
unveränderte Quelle und einen absichtlich veralteten Backupinhalt mit
Whole-Run-Cleanup einschließlich Restprüfung. Die lokalen Referenzabnahmen für
Docker und Podman bestanden getrennt am 2026-09-20 mit jeweils zwölf Assertions
und bestätigtem vollständigem Cleanup. Verlorene Antworten und Journalfehler
sind offline geprüft; native Prozessabbruchtests sind damit nicht belegt.

Mehrdatenbank- und Gesamt-Lab-Transfer, vorhandene Ziele, andere SQL-Versionen,
Windows/Hyper-V, providerübergreifende Migration, Serverobjekte, Logins,
Schlüssel sowie weitergehende Inhaltsprofile bleiben offen.
