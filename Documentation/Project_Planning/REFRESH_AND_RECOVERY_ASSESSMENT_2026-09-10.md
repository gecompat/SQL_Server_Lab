# Bewertung von Instanz-Refresh und Recovery Points

| Merkmal | Wert |
|---|---|
| Status | `validated` (Bewertung; keine neue Ausführung) |
| Stand | 2026-09-10 |
| Quellstand | `63e272d75c605552e3d7421791177c05191949de` |
| Auftrag | Bewertungszeilen „Vollständiger Evaluation-Refresh“ und „Recovery Points“ des [Arbeitsplans](AUTONOMOUS_DEVELOPMENT_WAVE_2026-09-10.md) |

## Vollständiger Evaluation-Refresh

Der fachlich akzeptierte [Refresh-Vertrag](FULL_INSTANCE_EVALUATION_REFRESH_BACKLOG.md)
bleibt sinnvoll: Eine neue, getrennte Umgebung kann einen ablaufenden Labstand
übernehmen, ohne dessen Lizenzzustand zurückzusetzen. Die Umsetzung folgt erst
nach den offenen State-, Persistenz-, Restore- und Reconcile-Abnahmen. Ein
generischer Instanzexport oder automatischer Cutover ist derzeit nicht
freigegeben. Der erste spätere Durchstich bleibt ein isoliertes lokales
Hyper-V-/Windows-/SQL-Evaluationspaar mit synthetischen Daten.

Der aktuelle [Abhängigkeitsvertrag](../../Private/DatabaseMigrationDependency.ps1)
ist ausdrücklich nicht ausführbar: `MutationAllowed=false`,
`TransferAuthority=NONE`, `FullInstanceMigration=false`. Er klassifiziert
SQL-Abhängigkeiten, behandelt externe Dienste aber als nicht beobachtet.
[Datenbankpakete](../../Private/DatabasePackage.ps1) übernehmen dadurch weder
Serverobjekte noch Keymaterial oder Secrets. Der bestehende
[Backup-Übergabepfad](../HowTo/PERSISTENT_DATA_AND_EVALUATION_REFRESH.md)
ist die Grundlage, kein vollständiger Refresh-Nachweis.

Die folgenden Entscheidungen konkretisieren den späteren Umsetzungsscope.
Der Aufwand ist relativ: **M** umfasst einen begrenzten Vertrag mit nativer
Abnahme, **L** mehrere gekoppelte Identitäts-, Daten- oder Recovery-Verträge.

| Gegenstand / Nutzen | Entscheidung und Abhängigkeit | Hauptrisiko / Aufwand | Nächster abnehmbarer Schritt |
|---|---|---|---|
| Quellinventar verhindert unbemerkte Verluste. | Bestehende SQL-Inventur erweitern; OS, SQL, Datenbanken, Serverobjekte, Schlüssel und externe Dienste getrennt klassifizieren. Nicht beobachtbar bleibt ein Blocker oder eine ausdrücklich behandelte manuelle Grenze. | Ein leeres Ergebnis wird irrtümlich als Abwesenheit gewertet; M. | Synthetischen Bestand mit einem absichtlich unbekannten Dienst inventarisieren; unbekannte Elemente und Drift zwischen Plan und Ausführung müssen die Vollständigkeitsfreigabe blockieren. |
| Datenbankübernahme erhält den fachlichen Inhalt. | Full-Backup und unabhängiger Restore zuerst; separate Zielpfade und neue Storage-Bindungen. Keine gemeinsame schreibbare MDF/LDF-Nutzung. | Nicht wiederherstellbares Backup, falsche Version oder fehlende Dateien; L. | Eine Datenbank mit festgelegten Zeilen-/Digest-Assertions auf dem frischen Ziel restaurieren und Konsistenz, Zielidentität sowie Cleanup prüfen. |
| Login/SID, Job und Konfiguration erhalten das Verhalten. | Im ersten Slice genau einen synthetischen Login/SID, einen eigenen T-SQL-Agent-Job und eine freigegebene Instanzkonfiguration übertragen beziehungsweise rekonstruieren. Zieljobs bis zum Cutover deaktiviert halten; Credentials nur lokal neu binden. | Verwaiste Benutzer, doppelte Jobausführung oder verlorener Verwaltungszugang; L. | Positive und negative Loginprobe, unveränderte SID-/Rechtebindung, einmalige Jobwirkung sowie wirksame Konfiguration nach notwendigem Dienstneustart nachweisen. |
| Schlüssel und Zusatzdienste bestimmen die Übertragbarkeit. | TDE, verschlüsselte Backups, FILESTREAM, SSISDB, SSAS und unbekannte externe Dienste blockieren den ersten Slice vor Mutation. Keine pauschale Erfolgsmeldung bei übersprungenen Komponenten. | Nicht entschlüsselbare Daten oder unvollständige Dienstidentität; L. | Je Fähigkeit zuerst einen eigenen Export-/Import-/Restore-Vertrag und eine isolierte native Negativabnahme definieren; Keymaterial bleibt getrennt geschützt. |
| Paralleler Aufbau begrenzt Ausfallzeit. | Quelle während Aufbau und Seed weiter betreiben; neue Maschinenidentität und explizite Zielbindung. Windows- und SQL-Fristen getrennt prüfen. | Zu wenig Speicher, falsche Edition oder Namens-/Endpointkonflikt; L. | Ressourcenbudget, Medien-/Lizenzmetadaten und unveränderte Quelle vor und nach dem Neuaufbau nachweisen. Ein Enterprise-Developer-Setup belegt keine SQL-Evaluationsfrist. |
| Cutover und Rückfall begrenzen Datenverlust. | Schreibsperre, letztes Delta, Zielprüfung und Endpointwechsel journalisieren. Vor Freigabe von Zielschreibzugriffen ist ein Rückfall auf die unveränderte Quelle möglich. Danach bleibt automatischer Rückfall ohne verifizierte Rücksynchronisierung blockiert. | Zwei Schreibquellen oder Verlust bereits am Ziel geschriebener Daten; L. | Fehler vor/nach jeder Umschaltgrenze und Prozessabbruch induzieren; genau eine schreibbare Seite und deterministisches Resume belegen. Quelle bis zum Ende der ausdrücklich festgelegten Rückfallfrist erhalten. |

`FULLY_EQUIVALENT` darf sich nur auf den vollständig inventarisierten und
explizit freigegebenen Scope beziehen. Eine manuelle Behauptung ersetzt keine
maschinelle Postcondition. Die Abschlussprüfung umfasst Dateninhalt,
Identitäten und Rechte, Jobwirkung, wirksame Konfiguration, Anwendungsprobe,
Rückfallübung und referenzgebundenes Cleanup. Die Bewertung führt diese
Schritte nicht aus und verändert keinen bestehenden Migrationsplan in einen
Executor.

## Verwaltete Recovery Points

Der Bedarf wird bestätigt, die Umsetzung bleibt providerbewusst. Der vorhandene
[read-only Plan](../../Private/RecoveryPointPlan.ps1) inventarisiert gebundene
Hyper-V-Checkpoints mit `ExecutionImplemented=false`. Sein Status `READY`
bedeutet, dass Kandidaten zur Prüfung vorliegen; er bestätigt weder
SQL-Konsistenz noch Wiederherstellbarkeit.

Der nächste vollständige Slice soll einen eigenen Hyper-V-SQL-2025-Run mit
kleiner synthetischer Datenbank sichern und in einem unabhängigen Ziel
wiederherstellen. Eine Standard-Checkpoint-Rückkehr oder das bloße Vorhandensein
einer VHDX reicht dafür nicht. SQL-Backups bleiben eine gesonderte
Wiederherstellungsebene; Docker und Podman erhalten keine behauptete
Hyper-V-Checkpoint-Parität.

| Gegenstand / Nutzen | Entscheidung und Abhängigkeit | Hauptrisiko / Aufwand | Nächster abnehmbarer Schritt |
|---|---|---|---|
| Konsistenz erhält einen verwendbaren SQL-Stand. | Konsistenzmethode vor Erstellung binden und ihre tatsächliche Ausführung erfassen. Bei Production-Checkpoint-Verfahren Gast-/VSS-Ergebnis und SQL-Postconditions prüfen; kein stiller Standard-Checkpoint-Fallback. | Crashzustand wird als SQL-konsistent ausgegeben; L. | Synthetische Transaktionsfolge vor/nach Sicherungsgrenze prüfen; fehlenden Konsistenzbeleg gezielt ablehnen. |
| Vollständige Disk- und Parentbindung verhindert Teilkopien. | VM-ID, Run-/Scope-ID, alle relevanten Daten-/Log-Lanes und Parentketten erfassen; ausgelagerte oder nicht erfasste Datenträger blockieren den vollständigen Scope. | Ein Checkpoint schützt nur einen Teil der SQL-Dateien; L. | Ein SQL-Run mit getrennter Daten-/Log-Ablage und eine fehlende Lane als Negativfall abnehmen. |
| Unabhängiger Restore belegt Wiederherstellbarkeit. | Neues Ziel mit eigenen Identitäten und beschreibbaren Dateien; Quelle bleibt erhalten. Keine Wiederherstellungsbehauptung allein aus Hash oder `VERIFYONLY`. | Gleiche defekte Quelle wird unbemerkt wiederverwendet; L. | Ziel ohne aktive Quelldateibindung starten, Datenbankkonsistenz und erwarteten Inhalt prüfen, Ziel anschließend vollständig bereinigen. |
| Retention und Referenzschutz erhalten benötigte Punkte. | Vorhandene Storage-/Lease- und Retention-Verträge verwenden; aktive Wiederherstellungen, Parentabhängigkeiten und Recovery-Zustände verhindern Entfernung. Alter allein erteilt keine Löschautorität. | Entfernte Parentdatei macht verbleibende Punkte unbrauchbar; M. | Geänderte Referenz zwischen Plan und Mutation, wiederholtes Cleanup und unterbrochenen Merge als Konflikt-/Resume-Fälle prüfen. |

Recovery Points übernehmen den bestehenden Lizenz-/Evaluationszustand und
werden deshalb nicht als Evaluation-Refresh verwendet. Ihre Einführung darf
keine automatischen Checkpoints einschalten oder bestehende Retentionregeln
umgehen. Die konkrete Reihenfolge und Providergrenzen bleiben im
[Plattformbacklog](CROSS_CUTTING_PLATFORM_CAPABILITIES_BACKLOG.md) und im
[Persistenzbacklog](PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md) verankert.

## Quellen und Prüfgrenze

Der Code-/Vertragsabgleich wurde auf dem oben genannten Quellstand durchgeführt.
Diese Bewertung enthält keine neue Runtime- oder Restore-Evidence.

Microsoft erläutert, warum Datenbankbenutzer ohne passende Serverlogins nach
einem Transfer verwaisen können, und beschreibt den gesonderten
[Login-/SID-Transfer](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/security/transfer-logins-passwords-between-instances).
Für [TDE-Datenbanken](https://learn.microsoft.com/en-us/sql/relational-databases/security/encryption/move-a-tde-protected-database-to-another-sql-server?view=sql-server-ver17)
muss der zum Entschlüsseln erforderliche Protektor am Ziel verfügbar sein;
Dateiübernahme allein genügt nicht. Die Herstellerdokumentation trennt
[Standard- und Production-Checkpoints](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/checkpoints)
und erklärt die Grenze von
[`RESTORE VERIFYONLY`](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-verifyonly-transact-sql?view=sql-server-ver17):
Das Backup wird dabei nicht tatsächlich restauriert und seine Datenstruktur
nicht vollständig geprüft. Diese Primärquellen wurden am 2026-09-10 gelesen;
die oben festgelegte Reihenfolge und der begrenzte Scope sind daraus und aus
den Repositoryverträgen abgeleitete Projektentscheidungen.
