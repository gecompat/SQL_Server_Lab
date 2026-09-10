# Console-UX – Folgebacklog

## Status

`ACTIVE`

Dieser Backlog hält die offenen Punkte fest, die bei der Konsolen-UX-Arbeit vom
2026-09-07 sichtbar geworden sind. Er ist Planung und kein Implementierungs-
oder Runtime-Nachweis. Jeder Punkt nennt den geprüften Ist-Zustand, damit die
Wiederaufnahme ohne Chat-Historie möglich ist.

## Umgesetzter Ausgangsstand

Die folgenden Punkte sind auf `main` verdrahtet und durch statische Verträge
gebunden. Sie sind hier nur als Ausgangspunkt genannt, nicht als offene Arbeit.

| Gegenstand | Bindender Vertrag |
|---|---|
| Synchrone Einzelerstellung ohne Queue-Umweg | Anti-Dead-Code-Prüfung der beteiligten Bausteine |
| Kopfzeile `Queue N · Worker x/y · Blockiert Z` | Statusband führt die Kopfzeile über Leerlauf und Laufzeit |
| Statusausfall kostet nicht die Cursoransicht | prozessgetrennter Modulnachweis |
| Deaktivierte Einträge: Marke vor Grund vor Label | Zeilenkomposition und schmales Fenster |
| Jede Aktion der `ValidateSet` ist über ein Menü erreichbar | Anti-Waisen-Prüfung |
| SA-Kennwort bleibt dem Eigentümer zugänglich | funktionaler Vertrag über einen temporären Run |

## Erledigter Punkt

### 1. Nächtliche Regression auf `main` – `RESOLVED`

Die ursprüngliche Bestandsaufnahme war zu pauschal. Der Workflow war vom
2026-09-03 bis 2026-09-07 rot, aber nicht in jedem Lauf ausschließlich wegen
Docker und Hyper-V. Zuvor waren die Nightly-Läufe bis einschließlich
2026-09-02 grün. Der Docker-Fehler vom 2026-09-07 war ein einzelner Abbruch
während des SQL-Bereitschaftswartens; der aktuelle Docker-Lifecycle
reproduziert ihn nicht.

Der Hyper-V-Smoke meldete im alten Lauf Erfolg und vererbte danach dennoch den
von einem nativen Hilfsprogramm gesetzten Exitcode. Commit `5261bc9` setzt nach
allen bereits ausnahmebasierten Fehlerpfaden den erfolgreichen
`$global:LASTEXITCODE` ausdrücklich auf `0`. Es war weder fehlendes Nested-
Hyper-V noch ein nicht ausführbarer Job.

Der manuell auf dem aktuellen `main`-Commit `0aba5e9` gestartete Lauf
[`Nightly Regression` 34159244948](https://github.com/gecompat/SQL_Server_Lab/actions/runs/34159244948)
bestätigt die Korrektur: alle Jobs einschließlich Docker, Podman, Hyper-V,
Mixed-Provider, Adapter, gemeinsamer SQL-Umgebungen und beider statischer
Plattformen sind erfolgreich. Damit ist der dauerhaft rote Zustand behoben;
neue Nightly-Fehler sind wieder als eigenständige Regressionen zu behandeln.

## Offene Punkte

### 2. Datenbankmenü vollständig ergänzt – `RESOLVED`

`database-menu` bietet nach dem Paket-Attach-Slice zwölf Einträge. Alle zuvor
fehlenden öffentlichen Backup-, Restore- und Paketfunktionen besitzen nun einen
sicheren interaktiven `Invoke-LabAction`-Fall.

Der erste read-only Slice ist am 2026-09-08 umgesetzt: Paketbestand und
Migrationsabhängigkeiten besitzen echte Produkt-Aufrufstellen im bestehenden
Menü „Datenbanken und Verbindungen“, passende Direktaktionen und kuratierte
Hilfe. Ein prozessgetrennter Modulnachweis ruft beide Handler gegen kontrollierte
Cmdlet-Doubles auf; der statische Vertrag prüft Menü, Handler, Direktaktion,
sichtbare Rückkehrbestätigung und einen fehlenden Handler als Gegenbeweis.
Der Backup-Slice ist am 2026-09-08 ergänzt. Er bindet Run, Instanz, Datenbank,
flüchtiges SA- und bei Hyper-V Gast-Credential sowie den registrierten
`Lab_Data`-Root vor einer ausdrücklichen Bestätigung. Das öffentliche Cmdlet
besitzt nun einen `ShouldProcess`-/`WhatIf`-Vertrag; der bestehende Core
veröffentlicht weiterhin erst nach `CHECKSUM`, `RESTORE VERIFYONLY`, SHA-256 und
atomarer Katalogregistrierung. Temporäre Dateien werden garantiert bereinigt,
TDE bleibt ohne Recovery-Vertrag fail-closed und die Menüausgabe enthält weder
Pfad noch Hash oder Credential.

Der Restore-Slice ist am 2026-09-08 ergänzt. Er bietet ausschließlich
vollständig revalidierte `REUSABLE`-BackupSets aus dem registrierten
`Lab_Data`, bindet Run und Instanz sowie flüchtige SQL-/Gast-Credentials und
prüft den Namen der Zieldatenbank vor der Mutation. Eine vorhandene Datenbank
erzwingt eine getrennte, standardmäßig abgelehnte `WITH REPLACE`-Bestätigung.
Der öffentliche Restore besitzt `ShouldProcess`/`WhatIf`, versucht temporäre
Gast- und Containerkopien im `finally`-Pfad garantiert zu entfernen und benennt
bei einem SQL-Teilfehler die notwendige Zielprüfung. Die Menüausgabe bleibt
pfad-, hash- und credentialfrei.

Der Paketexport-Slice ist am 2026-09-08 ergänzt. Er bindet ausschließlich eine
laufende Docker-/Podman-Quelle über Run- und Instanz-ID sowie den registrierten
`Lab_Data`-Root. Vor der ausdrücklichen Bestätigung werden der exklusive
`SINGLE_USER`-/`OFFLINE`-Übergang, der dauerhaft offline bleibende Quellzustand
und der Recovery-Weg ausgewiesen. Das SA-Secret stammt ausschließlich aus dem
gebundenen Run und wird weder erneut abgefragt noch ausgegeben. FILESTREAM und
TDE ohne Recovery-Nachweis scheitern vor der Offline-Mutation; temporäre
Kopien werden im `finally`-Pfad bereinigt. Die Ergebnisausgabe enthält nur
stabile Paket- und Storage-IDs, keine Pfade, Hashwerte oder Credentials.

Der Paket-Attach-Slice ist am 2026-09-08 ergänzt. Er wählt ausschließlich ein
katalogisiertes Paket per stabiler `DatabasePackageId`, bindet eine laufende
Hyper-V-SQL-Instanz per Run-/Instanz-ID und hält das Gast-Credential flüchtig.
Eine öffentliche `WhatIf`-Vorprüfung validiert Vollintegrität, SQL-Version,
FILESTREAM-Capability, leeren Zielzustand und das live von SQL gemeldete
Default-Data-Verzeichnis. Erst danach folgt die standardmäßig abgelehnte
Bestätigung für `COPY_THEN_ATTACH`. Ein getrennter Modus führt ausschließlich
ein exakt passendes `RECOVERY_REQUIRED`-Journal aus. Ergebnis und Menü bleiben
pfad-, hash- und credentialfrei.

Damit ist Punkt 2 abgeschlossen. Der Anti-Waisen-Vertrag umfasst alle sechs
ergänzten Datenbankaktionen und einen funktionalen Provider-Gegenbeweis je
mutierender Paketaktion.

### 3. Provider-Diagnoselog deckt nur die Containererstellung ab — RESOLVED

Seit 2026-09-08 führt `Invoke-LabProviderOperation` die relevanten mutierenden
Provideraufrufe aus und persistiert ihre Ausgabe einheitlich secretbereinigt.
Docker und Podman decken Containererstellung, Start, Stopp, Entfernung sowie
Volume-Anlage und -Initialisierung ab. Container-Tool-Image-Builds und der
Hyper-V-VM-Lifecycle verwenden denselben Vertrag. `provider.log` rotiert vor
dem Überschreiten von 4 MiB in höchstens drei Archive; funktionale Tests
beweisen Ausgabeerhalt, Fehlerweitergabe, Secretbereinigung und die
Rotationsgrenze.

### 4. Begründung deaktivierter Einträge ist unvollständig — RESOLVED

Seit 2026-09-08 besitzt jeder deaktivierbare Produkt-Menüeintrag einen expliziten
`-DisabledReason`, einschließlich Composer, Providerauswahl, Storage, CMS,
geschützter Umgebungen und Queue-Untermenüs. Die Mehrfachauswahl reicht den
Grund beim Erzeugen ihrer Anzeigeelemente weiter. Ein AST-basierter statischer
Vertrag inventarisiert Root-, Public-, Private-, Provider- und Tool-Skripte und
schlägt bei jedem neuen `New-LabConsoleItem -Disabled` ohne `-DisabledReason`
fehl; ein synthetischer Gegenbeweis belegt die Wirksamkeit.

### 5. Kuratierte Kontexthilfe deckt nur den kritischen Pfad ab — RESOLVED

Seit 2026-09-08 löst der zentrale Hilfekatalog alle 108 statisch verwendeten
`ScreenId`-Werte auf. Semantisch gleiche Auswahl-, Konfigurations-, Queue- und
Hyper-V-Schritte teilen bewusst kuratierte Definitionen; dynamische IDs wie
Provider-, Versions- und Review-Bildschirme werden über begrenzte Muster
aufgelöst. Jeder verwendete Bildschirm nennt Titel, Zweck und Folgewirkung,
relevante Gruppen zusätzlich Voraussetzungen, Hinweise und Cmdlet-Einstiege.
Ein statischer Vollständigkeitsvertrag blockiert neue unkuratierte `ScreenId`s
und beweist den generischen Fallback weiterhin mit einem Gegenbeispiel.

### 6. Statusband nur auf zwei Bildschirmen — RESOLVED

Seit 2026-09-08 stellt `Invoke-SqlServerLab` für die gesamte interaktive Sitzung
einen gemeinsamen Queue- und Fortschrittslieferanten bereit. Jeder untergeordnete
Menü- und Formularbildschirm erbt automatisch ein fest reserviertes dreizeiliges
Statusband. Hauptmenü und Queue behalten ihre expliziten Größen von drei und
fünf Zeilen. Explizite Bildschirmparameter bleiben autoritativ; Aufrufe außerhalb
der Produktsitzung warten weiterhin ohne Polling blockierend.

### 7. Secret-Referenz bestehender Composer-Positionen — RESOLVED

Seit 2026-09-08 bietet die gemeinsame Bearbeitung die Aktion
`SA-Secret-Referenz nachpflegen`. Sie bindet ausgewaehlte bestehende
`SqlEnvironment`-Positionen an eine vorhandene oder neu angelegte
`SQL_SERVER_LAB_SECRET_*`-Prozessvariable. Der Composer speichert ausschliesslich
den Variablennamen. Gemischt ausgewaehlte Windows-/Hyper-V-Positionen bleiben
unveraendert; eine reine Nicht-Containerauswahl deaktiviert die Aktion begruendet.

### 8. Weitere flache Bereichsmenüs — RESOLVED

| Menü | Einträge ohne `Zurueck` am 2026-09-08 | Bewertung |
|---|---:|---|
| `infrastructure-menu` | 3 | zwei fachliche Unterbereiche plus direkter read-only Infrastrukturstatus |
| `settings-menu` | 3 | drei eigenständige Einstellungen; keine reine Delegation |
| `hyperv-menu` | 4 | vier unterschiedliche Image-, Slot- und Verwaltungsabsichten |
| `database-menu` | 12 | durch Backup, Restore, Pakete, Inventur, Verbindung und KI fachlich ausgebaut |

Der einzige rein delegierende Bereich war `infrastructure-menu`. Er bietet nun
zusätzlich einen direkten, read-only Provider-, Laufzeit- und
Voraussetzungsstatus, ohne bestehende Shortcuts umzubelegen. Die anderen drei
Bereiche sind nach aktuellem Produktstand nicht mehr flach oder besitzen bereits
mehrere eigenständige Handlungen. Der statische Menüvertrag verhindert weiterhin
Bereiche mit weniger als zwei Handlungsoptionen.

### 9. Menüs und Befundliste berücksichtigen die tatsächliche Providerverfügbarkeit nicht — RESOLVED

Geprüfter Ist-Zustand vom 2026-09-08: Die Befundliste entstand zentral in
`Get-LabAttentionSnapshot` (`Private/AttentionStatus.ps1`). Die drei
Hyper-V-Befunde `template-pool-capacity-low`, `sql-slot-pool-low` und
`image-builds-pending` waren nur über `if ($IsWindows)` abgegrenzt, nicht
über die tatsächliche Verfügbarkeit. Auf einem Windows-Host ohne
verfügbares Hyper-V erschienen daher Hinweise wie „Nur 0 fertige
SQL-Pool-Slots; Mindestbestand ist 2. Loesung: Bei Bedarf neue Slots über
den Hyper-V-Pfad erzeugen.“, obwohl der genannte Lösungsweg dort nicht
ausführbar war. Der CU-Medienbefund `cu-media-*` („SQL … ist katalogisiert;
Windows-Paket fehlt.“) wurde ohne Providerbezug gemeldet; sein Lösungsweg
über das Windows-Paket setzt den Hyper-V-Pfad voraus.

Umsetzung am 2026-09-08: `Get-LabAttentionSnapshot` ermittelt die
Verfügbarkeit einmal je Snapshot über die kanonische
`Get-LabProviderAvailabilityMap` (bindet `Test-HyperVAvailable` für Hyper-V)
und erzeugt die drei Hyper-V-Befunde sowie den CU-Medienbefund
`cu-media-*` nur noch bei tatsächlich verfügbarem Hyper-V. Providerneutrale
Befunde (`media-root-missing`, `cu-catalog-*`, `cu-media-unverified-*`,
`cu-status-*-unavailable`, `run-recovery-required`) bleiben unverändert.
In den Menüs werden das Hyper-V-Bereichsmenü (`Show-LabHyperVMenu`, vier
Einträge), der mengenfähige Windows-Slot-Composer (`BulkSlots` in
`Show-LabCreateMenu`) und das Windows-CU-Paket im CU-Download
(`Invoke-LabCuResourceInteractive`) bei fehlendem Hyper-V begründet
über `-Disabled`/`-DisabledReason` deaktiviert; das bereits bestehende
Gating in `Show-LabMenu` und `Show-LabInfrastructureMenu` bleibt. Die
Erstellungsentscheidung selbst nutzte die Verfügbarkeit bereits über
`Get-LabProviderAvailabilityMap` und `Resolve-LabSqlIntentProvider`.

Nachweis: statischer Vertrag in `Tests/Static/Invoke-ConsoleUiChecks.ps1`
verlangt die Verfügbarkeitsbindung in der Befundliste sowie die begründete
Deaktivierung im Hyper-V-Menü, im Erstellungsmenü und im CU-Download.
Die Container-Providerauswahl im CU-Download (`cu-resource-provider`) und
die Erstellungsentscheidung werteten die Docker-/Podman-Verfügbarkeit
bereits aus; eine Änderung daran war nicht erforderlich.

### 10. Adhoc-Containererstellung mit Sample-Datenbank scheitert an später Connection-Info und verwirft die fertige Umgebung — RESOLVED

Geprüfter Ist-Zustand vom 2026-09-08 anhand des lokalen Sitzungsjournals
und Run-States: Die synchrone Einzelerstellung (ProvisioningMode `adhoc`,
Provider podman) erstellte den Container erfolgreich; SQL Server war nach
11,3 Sekunden bereit. Die Installation des Samples
`adventureworks-2025:full` scheiterte mit „Provisionierung fehlgeschlagen:
Connection-Info nicht gefunden fuer Run '<RunId>'.“. Der automatische
Cleanup entfernte danach Container und Volume (`CLEANUP_SUCCEEDED`); die
eigentlich fertige Umgebung war damit verloren. Ein Queue-Lauf vom Vortag
ohne Sample (`databases: []`) lief erfolgreich durch — der Fehler trat nur
in der Kombination Container-Provider plus Sample-Datenbank plus synchrone
Einzelerstellung auf.

Ursache: Der Sample-Schritt in `Public/New-SqlServerLab.ps1` rief
`Install-LabSampleDatabase` mit `-RunId` auf, obwohl Host, Port und
Containername explizit übergeben wurden. Der Handler löste bei gesetztem
`-RunId` das Ziel unbedingt über `Resolve-LabRunInstance`
(`Private/RunResolution.ps1`) auf; das warf, solange
`runs/<RunId>/connection-info.json` fehlte. Diese Datei wird im
Containerpfad erst am Ende von `New-SqlServerLab` geschrieben — nach dem
Sample-Schritt.

Umsetzung am 2026-09-08 (bevorzugte Richtung): `Install-LabSampleDatabase`
in `Private/SampleArtifactHandlers.ps1` löst nur noch dann über den Run
auf, wenn das Ziel nicht explizit übergeben wurde; `-RunId` bleibt für
RunDirectory und Journal nutzbar. Der `Resolve-LabRunInstance`-Vertrag für
Laufzeit-Cmdlets ist unverändert.

Nachweis: `Tests/Static/Invoke-SampleHandlerChecks.ps1` belegt die
Adhoc-Reihenfolge funktional — bei explizitem Ziel und gesetzter RunId
ohne `connection-info.json` wird der Resolver nicht aufgerufen und die
Installation endet mit `DATASET_READY`; der Gegenbeweis ohne explizites
Ziel ruft den Resolver auf und scheitert fail-closed mit derselben
Fehlersignatur wie im Realbefund. Lokale Runtime- und Diagnosedaten
wurden nur als beschriebener Ist-Zustand referenziert und nicht
versioniert.

### 11. Direkte Konsolenaktionen zeigen bei langen Phasen keinen Fortschritt — OPEN

Teilstand 2026-09-10: Der gemeinsame direkte Reporter, die vier Downloadpfade,
SQL-Readiness und die abgeleiteten Container-Image-Builds sind angebunden.
Feste Phasen und Messwerte vermeiden die Ausgabe von Pfaden, Argumenten und
nativen Rohdaten. Datei-/VHDX-Kopien in Registry und beiden Migrationspfaden
sowie die dortige und die Download-/Restore-Hashpruefung melden echte Bytewerte.
Offline-Tests decken Integritaet, Teilfehler und atomare Zielersetzung ab;
dies ist kein Nachweis fuer VM-Lifecycle oder produktive VHDX-Groessen.
ZIP-Backup-, Attach- und Script-Bundle-Payloads melden entpackte Bytewerte;
7-Zip-Pruefung und -Extraktion besitzen hostseitigen Heartbeat. Mehrteilige
Archive teilen sich einen Reporter bis zum Abschluss oder Fehler.
Native sqlcmd-Probes, Query-, Skript- und Restore-Aufrufe sind hostseitig
angebunden; mehrere Skriptbatches teilen sich eine Anzeige. SQL-Ergebnisdateien
werden nur kurzzeitig fuer eine eindeutige Unicode-Decodierung verwendet und
bei Erfolg, Fehler und Abbruch entfernt. Containerkopien fuer Restore, Attach
und Paketexport sowie BACPAC-Import und dessen Cleanup sind ebenfalls angebunden.
Der BACPAC-Fehlerpfad erfasst auch Teilkopien; Attach bewahrt weiterhin sein
Recovery-Journal. PowerShell Direct, Lab-WinRM, deren Readiness-/Restart-Probes,
Integrationstransfers und Prepared-Shutdown verwenden jetzt Hostreporter;
Offline-Jobs belegen Ausgabe, Fehlerkategorie, Timeout und eigenes Cleanup.
Session-Dateikopien fuer SQL-Storage und Datenbankpakete verwenden eine eigene
asynchrone Kopierpipeline; Offline-Nachweise decken Heartbeat, Ergebnisobjekte,
Fehlerkategorie, Timeout und Reporter-Cleanup ab.
Legacy-WMI und Hyper-V-Checkpoint-Cleanup sind ueber einen lokalen
Reporter-Runspace angebunden; er verwendet dieselbe Formatierung und
Allowlist und aktualisiert auch bei blockiertem Hauptthread. Verschachtelte
Schritte teilen einen Worker. Offline- und Terminalnachweis liegen vor;
vollstaendige neue Legacy-Gast-Evidence bleibt separat.
Native Gast-/Session-Evidence liegt mit CLI-Lauf 34427219338 auf 302a37d vor:
SQL-Lifecycle, bidirektionaler synthetischer Sessiontransfer mit Hashvergleich
und Cleanup bestanden. Der folgende Ausgangsbefund
beschreibt den Stand vor dieser Erweiterung.

Geprüfter Ist-Zustand vom 2026-09-09: Das feste Statusband (`CUI-022`) zeigt
Queue-Operationen mit Prozentbalken, Heartbeat, Laufzeit und
Stillstandserkennung. Direkte interaktive Aktionen verlassen jedoch den
Menürahmen und führen die Produktfunktion synchron aus. Sie erhalten damit
keinen Queue-Statuslieferanten. Bei SQL-Readiness, Server-Konfiguration,
Sample-Installation oder dem Aufbau einer automatisierten Testumgebung bleibt
zwischen der Start- und Erfolgsmeldung kein sichtbares Lebenszeichen.

Die Untersuchung fand außerdem konkrete lange Pfade ohne gleichwertige
Fortschrittsanzeige:

| Priorität | Produktpfad | Fehlende Rückmeldung | Verfügbare Fortschrittsdaten |
|---|---|---|---|
| `P0` | `Private/ArtifactResolver.ps1` | Der Sample-Download setzt `$ProgressPreference` ausdrücklich auf `SilentlyContinue`. | Native Web-Request-Fortschrittswerte |
| `P0` | `Public/Save-SqlServerLabMediaSource.ps1`, `Private/VersionCatalog.ps1` und `Private/ExternalRuntimeWindows.ps1` | Medien-, CU- und Runtime-Downloads besitzen keinen gemeinsamen sichtbaren Fortschrittsvertrag. | erwartete Bytes, übertragene Bytes, Verifikationsphase |
| `P0` | `Private/SqlReadiness.ps1` | Die Poll-Schleife meldet nur Start und Ende. | Timeout, Laufzeit, erfolgreiche Probes, Stabilisierung |
| `P0` | `Private/ContainerImageArtifact.ps1` und `Private/ContainerToolImage.ps1` | Abgeleitete Container-Image-Builds sammeln die native Ausgabe und zeigen währenddessen keinen Heartbeat. | Startzeit, aktive Build-Phase, native Ausgabezeilen |
| `P1` | `Private/HyperVImageMigration.ps1`, `Private/HyperVImageRegistry.ps1`, `Private/HyperVResourceMigration.ps1` | Große VHDX-Dateien werden kopiert und gehasht ohne pro Datei sichtbaren Fortschritt. | Dateianzahl, Dateigröße, Kopier-/Hashphase |
| `P1` | `Private/SampleArtifactHandlers.ps1`, `Public/Restore-SqlServerLabDatabase.ps1` und Container-Paketpfade | Archivextraktion, Containerkopien, `VERIFYONLY`, BACPAC-Import und Restore zeigen nur Phasenbeginn. | Payloadanzahl, Dateigröße, SQL-Phase, Timeout |
| `P2` | `Private/HyperVLabEnvironment.ps1` und weitere Gastwartepfade | Mehrminütige VM-, Netzwerk- und Aktivierungspolls haben teils keine hostseitige laufende Anzeige. | Deadline, Laufzeit, Poll-Status |

Zielvertrag: Jede interaktiv direkt gestartete Aktion mit einer erwartbaren
Wartezeit über fünf Sekunden zeigt sichtbar mindestens Aktivität, aktuelle
Phase und Laufzeit. Bei verfügbaren Messdaten zeigt sie zusätzlich einen
Prozent- oder Byte-Fortschrittsbalken. Meldungen im Gast oder erst nach Ende
eines nativen Prozesses gelten nicht als Heartbeat. Der Fortschrittswert darf
keine Secrets, lokalen Pfade, Hashwerte, Containerargumente oder unbereinigte
native Ausgaben enthalten.

Umsetzungsreihenfolge:

1. Einen gemeinsamen Reporter für synchrone Konsolenaktionen einführen, der
  Abschluss und Fehler garantiert beendet und für unbestimmte Phasen einen
  gedrosselten Heartbeat ausgibt.
2. Den explizit unterdrückten Artifact-Download freigeben und die drei
  Downloadpfade sowie SQL-Readiness auf den Reporter umstellen.
3. Große Datei-, Container- und SQL-Transfers mit Phasen-/Dateizählern
  anbinden; Byte-Fortschritt ist für Downloads und VHDX-Kopien erforderlich.
4. Die Hyper-V-Gastwartepfade hostseitig mit Deadline und Heartbeat ergänzen.

Nachweis bei der Umsetzung: Ein deterministischer Console-UI-Test prüft
Heartbeat, Laufzeit, Abschlussbereinigung und die Secretbereinigung des
Reporters. Je ein funktionaler Gegenbeweis belegt die Aktualisierung aus der
Readiness-Poll-Schleife und dem Artifact-Download. Die betroffenen statischen
Suites sowie ein direkter Podman-Lauf mit nicht gecachtem oder kontrolliert
simuliertem Sample-Download prüfen die sichtbare Bedienwirkung. Große
VHDX-/Hyper-V-Transfers erhalten getrennte Tests ohne echte mehrgigabytegroße
Dateien.

### 14. Hyper-V-Cleanup konnte eine Basis-VHDX trotz abhängiger Checkpoint-Disk entfernen — RESOLVED

Der reale Abgleich vom 2026-09-09 fand einen ausgeschalteten historischen
Run mit einer aktiven Checkpoint-AVHDX. Nach dem VM-Schritt war die Basis-VHDX
nicht mehr als VM-Anhang sichtbar, obwohl die Differenzdisk weiterhin von ihr
abhängt. Ein Löschversuch der Basisdatei hätte die Kette beschädigen können.

`Remove-HyperVVhdxForCleanup` inventarisiert deshalb vor jeder VHDX-Löschung
die lokalen VHDX-/AVHDX-Kandidaten und prüft ihre Parent-Beziehung. Eine
abhängige oder nicht lesbare Kette blockiert den Schritt mit einem stabilen
fail-closed Fehler. Ein verifizierter, höher priorisierter VM-Cleanup-Schritt
führt eine zugehörige Checkpoint-Kette scopegebunden zusammen, bevor er die VM
entfernt; ohne diesen Schritt bleibt der Run für eine explizite Bereinigung
und einen anschließenden Wiederholungs-Cleanup erhalten.

Nachweis: `Tests/Static/Invoke-CleanupAuditChecks.ps1` erzeugt eine
synthetische Basis-/AVHDX-Beziehung und verlangt, dass beide Dateien bei
`CLEANUP_BLOCKED` erhalten bleiben.

### 15. Cleanup-Audit meldete Hyper-V-Bindungen als untracked oder orphan — RESOLVED

Der reale read-only Audit vom 2026-09-09 bewertete live gebundene
VM-Konfigurationen, VHDX-Dateien und Checkpoints eines gültigen Hyper-V-Runs
zusätzlich als `UNTRACKED_HYPERV_RESOURCE`. Die gesonderte Run-Ordner-Prüfung
kannte zwar den Run, korrelierte ihn aber nicht mit der bereits verifizierten
Runtime-Bindung. Dadurch wirkte ein aktives Lab wie ein Löschkandidat.

`Get-SqlServerLabCleanupAudit` korreliert die Datei nun vor der
Untracked-Klassifikation mit einer nicht verwaisten `VERIFIED`-Storage-Bindung
derselben RunId. Die Korrelation ist read-only; ungebundene Dateien bleiben
weiterhin ausdrücklich als Preserve-Befund sichtbar.

Nachweis: `Tests/Static/Invoke-CleanupAuditChecks.ps1` verlangt die
Runtime-Bindungsprüfung im Auditvertrag. Der reale Abschlussaudit nach
scopegebundenem Reclaim der verwaisten VM-/Child-VHDX-Paare und nach Cleanup
des `REMOVED`-Run-Nachzüglers enthält 0 `ORPHAN`, 0
`UNTRACKED_HYPERV_RESOURCE`, 0 Recovery- und 0 Unverifiable-Befunde.

### 13. Cleanup-Audit klassifiziert aktive Container-Instanzstores fälschlich als verwaist — RESOLVED

Der reale read-only Audit vom 2026-09-09 meldete Instanzstores laufender
Docker-Umgebungen als `ORPHAN_CANDIDATE`. Ursache: Die Residency-Projektion
las Volume-Referenzen ausschließlich aus dem historischen Rootfeld
`run.instances`. Der aktuelle Statevertrag hält die Providerbindung jedoch in
`providerSubRuns`; nach dem Lifecycle kann das Rootfeld leer sein, obwohl das
Volume sein revalidiertes `sql-server-lab.run-id`-Label unverändert trägt.

`Get-LabStorageResidencyInventory` verwendet deshalb jetzt ausschließlich
für die read-only Projektion das revalidierte Volume-Run-Label als Fallback,
wenn es einen aktiven Run desselben Controllerzustands referenziert. Dies
verändert weder Runtime, State noch Cleanup-Autorität. Ein echter
unreferenzierter Store bleibt weiterhin `ORPHAN_CANDIDATE`.

Nachweis: `Tests/Static/Invoke-CleanupAuditChecks.ps1` entfernt im Fixture
gezielt die Root-Volume-Referenz und verlangt weiterhin eine aktive
Residency-Bindung über das Runtime-Label; derselbe Lauf belegt den
unreferenzierten Gegenfall.

### 12. Eine harmlose Warning kapert den Erstellungsfluss über den modalen Meldungsdialog — RESOLVED

Geprüfter Ist-Zustand vom 2026-09-08: Nach jeder Menüaktion rief
`Invoke-LabAreaMenuInteractive` (`Public/BatchConsole.ps1`) unterschiedslos
`Show-LabActionMessagesInteractive` auf, sobald mindestens eine neue
Meldung mit `Warning` **oder** `Error` vorlag. Die Auswahl des
Patchstandes `latest` erzeugt genau eine solche harmlose Hinweis-Warning
(„latest ist ein gleitender Microsoft-Tag …“). Daraufhin erzwang der
Dialog „Offene Meldungen der letzten Aktion“ den Fokus; dessen Taste `[m]`
führte in das Sitzungsjournal (Pfad-Ansicht). Der Bediener verließ damit
ungewollt den Erstellungsfluss, ohne dass eine Erstellung blockiert oder
ein Fehler vorgelegen hätte.

Umsetzung am 2026-09-08: `Show-LabActionMessagesInteractive` gibt reine
Warnungen nur noch als sichtbaren, markierbaren Text im Scrollback aus und
verweist auf das Meldungsjournal im Hauptmenü; der modale Dialog erscheint
ausschließlich bei mindestens einer Meldung mit `severity = 'Error'`. Der
Dialog heißt folgerichtig „Fehler der letzten Aktion“. Die Warning bleibt
damit unmittelbar sichtbar, unterbricht aber den Fluss nicht mehr. Der
Hilfekatalog-Eintrag `action-messages` (`Private/ConsoleHelp.ps1`) wurde
entsprechend angepasst. Zusätzlich erhielt `New-LabConsoleField` ein
`Disabled`/`DisabledReason`-Konzept analog zu `New-LabConsoleItem`, damit
ein erzwungener, nicht editierbarer Formularwert (Netzwerkmodus in der
Schnellkonfiguration) begründet und nicht fokussierbar statt als scheinbar
auswählbarer Eintrag erscheint.

Nachweis: statischer Vertrag in `Tests/Static/Invoke-ConsoleUiChecks.ps1`
verlangt, dass der Dialog nur bei Fehlern aufgerufen wird und dass das
Schnellkonfigurations-Netzwerkmodus-Feld begründet deaktiviert ist;
Gegenbeweis durch Rücknahme der Änderung belegt den Fehlschlag.

## Bindende Erkenntnisse für die Wiederaufnahme

Diese Punkte haben in der Arbeit vom 2026-09-07 jeweils einen realen Defekt
verursacht oder verdeckt. Sie gelten unabhängig vom einzelnen Backlog-Punkt.

- **Ein Baustein ohne Aufrufstelle im Produktivcode ist keine Funktion der
  Oberfläche.** `Resolve-LabSqlIntentProvider`, `Invoke-LabNewContainerEnvironmentInteractive`,
  `Invoke-LabNewHyperVEnvironmentInteractive`, `UpdateContainer` und
  `AutomatedTestEnvironment` waren vollständig implementiert und validiert, aber
  aus der Oberfläche nicht erreichbar.
- **Ein Vertrag im dot-sourced Testscope kann Scope-Fehler des Produkts nicht
  finden.** Die Cursorsteuerung von Haupt- und Vorgangsmenü war vollständig
  ausgefallen, während die Suite grün blieb. Wer eine Closure oder eine
  modulprivate Auflösung prüft, muss das Modul importieren und in einem eigenen
  Prozess laufen.
- **Ein Vertrag, der nicht fehlschlagen kann, ist wertlos.** Für jede neue
  Zusicherung ist der Gegenbeweis zu führen: Änderung zurücknehmen, Fehlschlag
  belegen.
- **Ein Test, der Hostausstattung abfragt, ist kein Vertrag.** Der
  Batch-Preflight hing an der echten Providerverfügbarkeit und war auf
  `windows-latest` zufällig rot oder grün.
- **Ein zurückgehaltenes Kennwort schützt nichts, wenn das Werkzeug es selbst
  laufend entschlüsselt.** Es sperrt nur den Eigentümer aus.

## Wiederaufnahme

Die Reihenfolge ist nicht festgelegt. Nach Erledigung von Punkt 1 ist Punkt 2
der größte fachliche Zugewinn, erfordert aber neue interaktive Pfade und damit
einen eigenen Änderungssatz je Funktion.

Für Reihenfolge und Priorität gegenüber anderen Vorhaben bleibt
`DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md` maßgeblich.
