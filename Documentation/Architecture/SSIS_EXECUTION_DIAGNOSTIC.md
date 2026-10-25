# Lesende Diagnose des SSISDB-Ausführungskontexts

`Get-SqlServerLabSsisExecutionDiagnostic` untersucht eine bereits vorhandene
Ausführung eines eigenen Windows-/Hyper-V-/SQL-2025-Runs. Die
[Paketladediagnose](SSIS_PACKAGE_DIAGNOSTIC.md) beobachtet dagegen das SDK im
Administratorprozess. Die neue Diagnose liest Katalogmetadaten, bekannte
SSIS-Dateien und Registrierungen sowie gegebenenfalls den noch laufenden
`ISServerExec`-Prozess. Sie startet und validiert kein Paket und führt kein
Setup, keine Reparatur und keine Loggingänderung aus.

## Vorbereitung und Aufruf

Execution-ID, Projekt-LSN und Katalogdatenbankkennung stammen aus derselben
privaten Consumer-Receipt.
Die Katalogdatenbankkennung bezeichnet dabei wie im Analyze-Consumervertrag
`sys.databases.service_broker_guid` der SSISDB, nicht die Recovery-Kennung.
Ein inzwischen entferntes Projekt verhindert die
Beobachtung seiner noch sichtbaren Ausführungsmetadaten nicht. Fehlt die
Ausführung nach der Katalogbereinigung oder weicht ihre Bindung ab, bleibt der
Befund unbestätigt. Freie Hosts, Ports, Gastpfade, Credentials und Skripte sind
keine Parameter dieser API.

```powershell
$diagnostic = Get-SqlServerLabSsisExecutionDiagnostic -RunId $runId `
    -InstanceId primary -ExecutionId $receipt.ExecutionId `
    -ExpectedProjectLsn $receipt.ProjectLsn `
    -ExpectedCatalogDatabaseGuid $receipt.CatalogDatabaseGuid `
    -TimeoutSeconds 60
```

Der bestehende [Windows-Consumerzugang](../HowTo/SSIS_CONSUMER_WINDOWS_ACCESS.md)
bleibt maßgeblich. Der Operator benötigt Hyper-V-/PowerShell-Direct-Rechte und
Zugriff auf die geschützte Gastanmeldung. SQL verbindet sich ausschließlich im
Gast per Windows-Anmeldung mit Verschlüsselung zur gespeicherten Instanz.
SQL2025, Instanz, Authscheme, Sysadminsicht, Katalogkennung, Execution-ID und
Projekt-LSN werden vor der Beobachtung geprüft. Die SQL-Bindung wird am Ende
und die Run-/Scope-/Instanz-/VM-Bindung vor und nach dem einmaligen Gastaufruf
erneut gelesen. Es gibt weder einen Versions-/SQL-Auth-Fallback noch einen
Transportretry. SQL2019, SQL2022 und Linux sind für diesen Diagnoseweg nicht
freigegeben. Der Aufruf hat eine harte Transportfrist von 10 bis 120 Sekunden.

## Ergebnisse auswerten

Die geschlossene Rückgabe `SqlServerLab.SsisExecutionDiagnostic/1.0` enthält
`Target`, `Status`, `ReasonCode`, `Observation`, `ReadOnly=true` und
`ExecutionStatus=NOT_STARTED_BY_DIAGNOSTIC`. Der Host prüft Typen, Bindungen,
Grenzen und widersprüchliche Erfolgsangaben und projiziert sämtliche Ebenen neu.
Remotingfelder, Konten, Pfade, Paketinhalt und Meldungstexte werden nicht
weitergereicht. Rohdiagnosen bleiben im privaten lokalen Consumerbereich.

| Beobachtung | Bedeutung und Grenze |
|---|---|
| `Snapshot` | Die anfangs gelesene Ausführungskennung, Projekt-LSN, Katalogkennung, Status, angeforderte Bitness und Windows-Authscheme sind an die Eingabe gebunden. Statusänderungen während der Beobachtung bleiben möglich. |
| `InstalledFiles` | Sechs feste Rollen für Executor, DTS, Verbindungen, Pipeline, Logging und Execute Package liefern Dateiversion, Major, PE-Architektur und SHA-256 oder ausdrücklich `MISSING` beziehungsweise `UNAVAILABLE`. Eine vorhandene Datei beweist keine erfolgreiche Aktivierung. |
| `Registration` | Beide Registry-Sichten liefern den beobachteten Zustand der festen `170\DTS\Setup`-Registrierung und ausschließlich geschlossene Editionswerte. Diese Metadaten ersetzen keinen MSI- oder Funktionstest. |
| `ComRegistration` | Sechs feste Rollen-/Registry-Sicht-Paare melden vorhandene oder fehlende native COM-Registrierung und gegebenenfalls den Major ihrer Datei im erwarteten DTS-Verzeichnis. Es erfolgt keine COM-Aktivierung. |
| `Worker` | Ein aktiver Katalogprozess kann als `RUNNING_CANDIDATE` mit Startzeit und bis zu sechs bekannten Modulrollen beobachtet werden. Prozess-ID, erwartetes Image, Erstellungszeit und erneuter Katalogread begrenzen die Zuordnung; sie sind keine kryptografische Prozess- oder Tokenattestation. |
| `ErrorCodes` | Höchstens 64 unterschiedliche numerische Codes der vorhandenen Fehlerereignisse werden gelesen. Fehlende Codes beweisen keine Fehlerfreiheit. Eine Überschreitung bleibt `INCONCLUSIVE`. |

Ohne gemeldete Prozess-ID lautet der Workerstatus `NOT_REPORTED`. Eine bereits
terminale Ausführung erhält `NOT_INSPECTED_TERMINAL`; ihre historische PID wird
nicht als aktueller Prozess adoptiert. Die Kandidatenprüfung erwartet den
64-Bit-Executor; ein 32-Bit-Worker wird nicht als bestätigter Kandidat gemeldet. `NOT_RUNNING` bezeichnet einen beim
Zugriff nicht mehr vorhandenen Prozess. Abweichende Identität, beendete
Ausführung während des Reads und Inspektionsfehler bleiben eigene Zustände.
Die Dateihashes betreffen die am beobachteten Pfad gehaltenen Dateien, keine
Speicherabbilder oder vollständige Modul-Ladeliste.

`OBSERVED` bestätigt die strukturierte Metadatenbeobachtung. Es bedeutet weder,
dass alle Dateien und Registrierungen vorhanden sind, noch dass ein Worker
beobachtet wurde oder die Ausführung erfolgreich war. `INCONCLUSIVE` mit
`SQL_BINDING_MISMATCH`, `SQL_OBSERVATION_UNAVAILABLE`, `CAPTURE_FAILED` oder
einem Host-/Transportfehler darf nicht als Funktionsnachweis verwendet werden.
Eine Aktivierungs- oder Reparaturhypothese benötigt weiterhin einen eigenen
gebundenen Pakettest. Die erhaltene SSISDB wird durch diesen Befehl nicht
entfernt oder neu angelegt.

Dateireads sind auf fünf bekannte Rollen, 64 MiB je Datei und insgesamt
256 MiB gehashte Bytes begrenzt. Reparse Points und abweichende Verzeichnisse
werden vor einer Dateibeobachtung abgewiesen. Registrierungen werden nur
lesend geöffnet. Es gibt keinen dauerhaften Diagnosejournal- oder zusätzlichen
Cleanupzustand im Lab-Run. Die vorhandenen Parser und die Lineage anderer
Projekte werden nicht übernommen.

## Validierung

Die fokussierte Suite `Tests/Static/Invoke-SsisExecutionDiagnosticChecks.ps1`
prüft synthetische SQL-Metadaten, die produktive Gastprojektion, große IDs,
Bindungswechsel, einmaligen Transport und verschachtelte Datenbegrenzung.
Nur SQL-, Registry-, Dateiwurzel- und Prozessgrenzen des Gasttests werden ersetzt.
Die [Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md#ssisdb-ausführungskontextdiagnose)
trennt diese Prüfungen von tatsächlichen Gastbeobachtungen. Eine gesonderte
native Paketausführung bleibt Voraussetzung für eine SSIS-Funktionsabnahme.
