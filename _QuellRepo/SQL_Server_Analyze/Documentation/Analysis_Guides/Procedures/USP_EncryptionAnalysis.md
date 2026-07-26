# [monitor].[USP_EncryptionAnalysis]

**Bereich:** Versionsadaptive Spezialanalysen<br>
**Zweck:** Bewertet sichtbare TDE-, Schutzobjekt-, Backupverschlüsselungs-, Always-Encrypted- und Ledger-Metadaten ohne Schlüsselmaterial oder geschützte Inhalte.<br>
**Beobachtungsart:** Snapshot + retentionbegrenzte Metadatenhistorie<br>
**Kostenklasse:** MEDIUM

## Entscheidungsfrage und Einsatz

Die Procedure beantwortet die Betriebsfrage: **Welche TDE-/Verschlüsselungszustände und Key-/Certificate-Abhängigkeiten sind sichtbar, ohne Schlüsselmaterial offenzulegen?** Sie unterstützt die Entscheidung, ob das Spezialfeature vorhanden und in einem auffälligen Zustand ist und welches featureeigene Diagnoseverfahren als Nächstes gebraucht wird.

## Nicht beantwortete Fragen

Die Procedure beantwortet keine fachliche Korrektheit der Featurekonfiguration, keine geschützten Inhalte und keine End-to-End-Funktionsprüfung außerhalb sichtbarer Metadaten. Der Zeitvertrag ist im Abschnitt „Zeit- und Scope-Modell“ konkretisiert. Ein Einzelwert gilt daher nur für diesen Scope und Zeitpunkt; er belegt weder eine Ursache noch eine Entwicklung.

## Sicherer Einstieg

```sql
EXEC [monitor].[USP_EncryptionAnalysis]
      @DatabaseNames = N'[ExampleDatabase]',
      @NurProblematisch = 1,
      @ResultSetArt = 'CONSOLE';
```

Alle `Example*`-Werte im Aufruf sind synthetisch.

## Resultsets und Leserichtung

Der typisierte TABLE-Vertrag registriert `databases`. Status, Scope und Warnings sind vor den Fachergebnissen zu lesen. CONSOLE dient der interaktiven Triage; RAW und JSON erhalten den technischen Kontext, während TABLE nur die ausdrücklich benannten stabilen Resultsets schreibt. Resultsets mit unterschiedlicher Zeilengranularität dürfen nicht ungeprüft vereinigt oder summiert werden.

## Eine Zeile bedeutet

Eine Datenbankzeile verbindet TDE-Zustand, sichtbaren Schutzobjekt-Lebenszyklus, den letzten sichtbaren Full-Backup-Verschlüsselungsstatus und ausschließlich aggregierte Featureanzahlen. Quellenstatus und Datenbankwarnungen sind eigene Zeilentypen.

## So lesen

Prüfen Sie zuerst `StatusCode`, `IsPartial` und Quellenstatus. Berücksichtigen Sie danach `EncryptionStateDesc` und `EncryptionScanStateDesc`. Zertifikatablauf und lokaler Exportzeitpunkt sind Betriebsindizien. `LatestFullBackupExplicitlyEncrypted` beschreibt nur explizite Backupverschlüsselung; TDE ist davon getrennt.

## Warum kann das problematisch sein?

Ein suspendierter oder abgebrochener TDE-Scan, ein nicht sichtbares Schutzobjekt oder fehlende erwartete Backupverschlüsselung kann einen laufenden Schutz- oder Wiederherstellungsprozess beeinträchtigen. Ohne externe Schlüsselkopie kann ein Restore trotz intakter Backupdatei unmöglich sein.

## Wann ist es kein Problem?

Eine unverschlüsselte Datenbank ist ohne entsprechende Schutzvorgabe kein Fehler. Ein leerer lokaler Zertifikat-Backupzeitpunkt beweist nicht, dass keine externe Kopie existiert. Ein Zertifikatablauf beendet bestehende TDE-Verschlüsselung nicht automatisch. Always-Encrypted- und Ledger-Anzahlen sind Inventarkontext, kein Health-Urteil.

## Beispiele und Gegenbeispiele

**Synthetischer Problemfall (`Example*`):** Ein suspendierter oder abgebrochener TDE-Scan, ein nicht sichtbares Schutzobjekt oder fehlende erwartete Backupverschlüsselung kann einen laufenden Schutz- oder Wiederherstellungsprozess beeinträchtigen. Ohne externe Schlüsselkopie kann ein Restore trotz intakter Backupdatei unmöglich sein.

**Ähnlich aussehender Gegenfall:** Eine unverschlüsselte Datenbank ist ohne entsprechende Schutzvorgabe kein Fehler. Ein leerer lokaler Zertifikat-Backupzeitpunkt beweist nicht, dass keine externe Kopie existiert. Ein Zertifikatablauf beendet bestehende TDE-Verschlüsselung nicht automatisch. Always-Encrypted- und Ledger-Anzahlen sind Inventarkontext, kein Health-Urteil. Der gleiche Einzelwert kann deshalb bei `ExampleDb` ohne Nutzerauswirkung unkritisch sein, während er bei zeitgleicher SLA-Verletzung eine Vertiefung rechtfertigt.

## Leere oder partielle Ausgabe

Nicht installiert, nicht aktiviert, in der gewählten Datenbank nicht verwendet und nicht abfragbar sind vier verschiedene Zustände.

Für `USP_EncryptionAnalysis` gilt zusätzlich: **keine Zeile** bedeutet, dass im sichtbaren und gefilterten Scope kein ausgabefähiger Datensatz entstand. **0** ist ein gemessener Nullwert nur dann, wenn die Quellspalte tatsächlich verfügbar war. **NULL** bedeutet unbekannt, nicht anwendbar oder nicht auflösbar. **PARTIAL/Warning** bedeutet, dass mindestens eine Teilquelle, Datenbank oder Detailstufe fehlt. Ein Limit kann eine nichtleere Quelle vollständig aus dem sichtbaren Ausschnitt verdrängen.

## Eigenlast und Grenzen

Die Procedure liest keine Schlüsselpfade, Signaturen, verschlüsselten Werte, Backupmedien, Konten oder privaten Schlüssel und gibt keine Thumbprints aus. Ein erfolgreicher isolierter Restore mit autorisiertem Schlüsselmaterial bleibt externer Nachweis.

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | MEDIUM |
| Standardpfad | Eine `ExampleDatabase`, Problemscope, 35 Tage Backup-Lookback und endliches Limit. Gelesen werden TDE-/Zertifikat-, Always-Encrypted-, Ledger- und aggregierte Backupmetadaten, niemals Schlüsselmaterial. |
| Teuerster Pfad | Alle sichtbaren Datenbanken, sehr großer Backup-Lookback und unbegrenzte Ausgabe auf einer Instanz mit umfangreicher `msdb.dbo.backupset`-Historie sowie vielen sichtbaren Schutzobjekten. Ein separater Deep-Modus existiert nicht. |
| Haupttreiber | Zahl gewählter Datenbanken, TDE-/Zertifikat-/Schlüsselmetadaten, Always-Encrypted- und Ledgerobjekte sowie verschlüsselte Backupsets im Lookback. Schlüsselmaterial und geschützte Nutzdaten werden nicht gelesen. |
| Skalierung | Datenbankpfad wächst mit Schutzobjekten/verschlüsselten Spalten; der Backupbeleg wächst mit Datenbankanzahl, Lookback und msdb-Retention. Ergebnisaggregation und Sortierung folgen der vollständig materialisierten Metadatenmenge. |
| Ressourcen | CPU und Katalog-/msdb-I/O, insbesondere `sys.dm_database_encryption_keys`, Zertifikats-/Schlüsselkataloge und `msdb.dbo.backupset`; kleine temporäre Ergebnistabellen. |
| Begrenzungswirkung | Datenbankscope und `@BackupLookbackDays` begrenzen relevante Quellarbeit. `@NurProblematisch` und `@MaxZeilen` wirken erst auf die erzeugte Auswertung und reduzieren vor allem Rückgabe/JSON. |
| Locking und Nebenwirkungen | Rein lesend; keine Schlüssel-, Zertifikat- oder Konfigurationsänderung und kein Zugriff auf Backupmedien. Katalog und msdb werden nacheinander gelesen, weshalb ein parallel laufendes Backup oder eine Schlüsselrotation einen Mischstand erzeugen kann. |
| Schutzmechanismus | Der Kandidatenpfad verwendet `@AnalysisClass = NULL`; `@HighImpactConfirmed` schaltet hier keinen teureren Pfad frei. Schutz bieten Einzeldatenbank-Scope, Lookback und `@LockTimeoutMs`. |
| Sicherer Einsatz | Eine `ExampleDatabase`, begrenzter Backup-Lookback und Problemscope; Zertifikat-/Restoreaussagen immer gegen autorisierten externen Export- beziehungsweise Test-Restore-Nachweis prüfen. |
| Aussagegrenze | Scope- oder Zeilenbegrenzungen können relevante, seltene oder später einsortierte Zeilen ausblenden. Die Aussage bleibt auf das Modell „Snapshot + retentionbegrenzte Metadatenhistorie“, die dokumentierte Granularität und den sichtbaren Quellenscope begrenzt; ein kleines Resultset ist weder automatisch vollständig noch repräsentativ. |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

Welche TDE-/Verschlüsselungszustände und Key-/Certificate-Abhängigkeiten sind sichtbar, ohne Schlüsselmaterial offenzulegen?

### Technischer Hintergrund

TDE verschlüsselt Daten-/Logseiten at rest über Database Encryption Key, geschützt durch Server Certificate/Asymmetric Key in `master` oder EKM. `sys.dm_database_encryption_keys` zeigt State/Percent/Algorithm/Protector. Restore auf anderer Instanz benötigt passenden Protector/Private Key. Backups können zusätzlich separat verschlüsselt sein.

### Datenkette

`msdb.dbo.backupset`, `sys.column_encryption_keys`, `sys.column_master_keys`, `sys.columns`, `sys.databases`, `sys.tables`, `master.sys.certificates`, `sys.dm_database_encryption_keys`.

### Source Select

Der TDE-Kern verbindet den Datenbankkatalog mit dem Encryption-Key-Laufzeitzustand:

```sql
SELECT
      [d].[name] AS [DatabaseName]
    , [dek].[encryption_state]
    , [dek].[percent_complete]
    , [dek].[encryptor_type]
    , [dek].[encryptor_thumbprint]
FROM [sys].[databases] AS [d] WITH (NOLOCK)
LEFT JOIN [sys].[dm_database_encryption_keys] AS [dek] WITH (NOLOCK)
  ON [dek].[database_id] = [d].[database_id]
WHERE [d].[name] = N'ExampleDatabase';
```

**Wichtig für die Eigenlast:** Setzen Sie Datenbankfilter vor Zertifikats-, Backup- und Always-Encrypted-Katalogpfaden. Die Procedure gibt keine Schlüsselmaterialien aus; Zertifikats- und Backupprüfung sind getrennte Metadatenzweige.

### Zeit- und Scope-Modell

Die Auswertung beschreibt den aktuellen Encryption-/Keymetadatenzustand; Rotation/Scan kann Fortschrittszustände zeigen.

### Bewertung und Gegenprobe

Prüfen Sie Encryption State, Percent Complete, Algorithm und Key Length, Encryptor Type, Zertifikatsablauf und Backupstatus, TempDB- und Systemkontext sowie Restoregovernance. Geben Sie ausschließlich öffentliche Metadaten aus und übernehmen Sie keine Thumbprints oder Keybytes in Artefakte.

### Typische Fehlinterpretation

`ENCRYPTED` beweist nicht, dass Zertifikat/Private Key sicher gesichert und Restore getestet wurde. TDE schützt nicht vor berechtigten SQL-Abfragen oder Datenexfiltration im laufenden System.

### Folgeanalyse

Für die weitere Analyse gelten folgende Schritte und Quellen: Certificate-/Key-Backupinventar in einem geschützten Zielsystem, echter Restoretest und Securitypolicy.

## Primärquellen

- [Transparent Data Encryption](https://learn.microsoft.com/en-us/sql/relational-databases/security/encryption/transparent-data-encryption?view=sql-server-ver17)

[Technische Detailbeschreibung](../09_Version_Adaptive.md)
