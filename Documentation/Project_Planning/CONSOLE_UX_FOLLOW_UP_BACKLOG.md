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

### 9. Menüs und Befundliste berücksichtigen die tatsächliche Providerverfügbarkeit nicht — OPEN

Geprüfter Ist-Zustand vom 2026-09-08: Die Befundliste entsteht zentral in
`Get-LabAttentionSnapshot` (`Private/AttentionStatus.ps1`). Die drei
Hyper-V-Befunde `template-pool-capacity-low`, `sql-slot-pool-low` und
`image-builds-pending` sind nur über `if ($IsWindows)` abgegrenzt, nicht über
`Test-HyperVAvailable`. Auf einem Windows-Host ohne verfügbares Hyper-V
erscheinen daher Hinweise wie „Nur 0 fertige SQL-Pool-Slots; Mindestbestand
ist 2. Loesung: Bei Bedarf neue Slots über den Hyper-V-Pfad erzeugen.“,
obwohl der genannte Lösungsweg dort nicht ausführbar ist. Der
CU-Medienbefund `cu-media-*` („SQL … ist katalogisiert; Windows-Paket
fehlt.“) wird ohne Providerbezug gemeldet; sein Lösungsweg über das
Windows-Paket setzt den Hyper-V-Pfad voraus.

In den Menüs ist das Hyper-V-Gating bereits teilweise umgesetzt
(`Show-LabMenu` und `Show-LabInfrastructureMenu` mit `-Disabled` und
`-DisabledReason` aus `New-LabConsoleItem`); die Docker-/Podman-
Verfügbarkeit wird dagegen in keinem Menü ausgewertet. Die kanonischen
Prüfungen sind vorhanden: `Test-HyperVAvailable`
(`Providers/HyperV/HyperVProvider.ps1`), `Resolve-LabHostTool`
(`Private/HostToolResolution.ps1`) und `Get-AvailableLabProviders`
(`Public/Invoke-SqlServerLab.ps1`).

Zielvertrag: Befunde, deren Lösungsweg einen nicht verfügbaren Provider
erfordert, werden gar nicht erzeugt. Menüeinträge, die einen nicht
verfügbaren Provider voraussetzen, werden mit begründetem `-Disabled`
deaktiviert; das Erstellungsmenü bietet nur verfügbare Provider an, und
„Provider Auto“ wählt ausschließlich aus verfügbaren. Die Verfügbarkeit
wird einmal je Snapshot- beziehungsweise Menüaufbau ermittelt und
weitergereicht; ein Mehrfach-Probe von `Get-VMHost` oder
`docker info` je Eintrag ist ausgeschlossen. Prüfliste der Befunde für die
Umsetzung:

| Befund | Providerbindung |
|---|---|
| `media-root-missing`, `cu-catalog-date-missing`, `cu-catalog-stale`, `cu-media-unverified-*`, `cu-status-*-unavailable`, `run-recovery-required` | providerneutral, bleiben unverändert |
| `cu-media-*` („Windows-Paket fehlt“) | nur melden, wenn der Hyper-V-Pfad verfügbar ist |
| `template-pool-capacity-low`, `sql-slot-pool-low`, `image-builds-pending` | nur bei verfügbarem Hyper-V |

Nicht-Ziele: keine Änderung an der Provider-Erkennung selbst, an der
Batch-/Queue-Auswahl oder an nicht-interaktiven Pfaden.

Nachweis bei der Umsetzung: statischer AST-Vertrag, der die drei
Hyper-V-Befunde und den CU-Medienbefund hinter einer
Verfügbarkeitsprüfung verlangt, plus funktionaler Test mit gemockter
Verfügbarkeit inklusive Gegenbeweis.

### 10. Adhoc-Containererstellung mit Sample-Datenbank scheitert an später Connection-Info und verwirft die fertige Umgebung — OPEN

Geprüfter Ist-Zustand vom 2026-09-08 anhand des lokalen Sitzungsjournals
und Run-States: Die synchrone Einzelerstellung (ProvisioningMode `adhoc`,
Provider podman) erstellte den Container erfolgreich; SQL Server war nach
11,3 Sekunden bereit. Die Installation des Samples
`adventureworks-2025:full` scheiterte mit „Provisionierung fehlgeschlagen:
Connection-Info nicht gefunden fuer Run '<RunId>'.“. Der automatische
Cleanup entfernte danach Container und Volume (`CLEANUP_SUCCEEDED`); die
eigentlich fertige Umgebung war damit verloren. Ein Queue-Lauf vom Vortag
ohne Sample (`databases: []`) lief erfolgreich durch — der Fehler tritt nur
in der Kombination Container-Provider plus Sample-Datenbank plus synchrone
Einzelerstellung auf.

Ursache: Der Sample-Schritt in `Public/New-SqlServerLab.ps1` ruft
`Install-LabSampleDatabase` mit `-RunId` auf, obwohl Host, Port und
Containername explizit übergeben werden. `Install-LabSampleDatabase`
(`Private/SampleArtifactHandlers.ps1`) löst bei gesetztem `-RunId` das Ziel
unbedingt über `Resolve-LabRunInstance` (`Private/RunResolution.ps1`) auf;
das wirft, solange `runs/<RunId>/connection-info.json` fehlt. Diese Datei
wird im Containerpfad erst am Ende von `New-SqlServerLab` geschrieben —
nach dem Sample-Schritt. Der Hyper-V-Pfad ist nicht betroffen (frühe,
mehrfache Schreibzugriffe in `Private/HyperVLabEnvironment.ps1`); der
Queue-Pfad mappt bislang keine Samples (`CreateContainerEnvironment` in
`Private/BatchWorkflow.ps1`).

Zielvertrag: Die Sample-Installation darf in der Adhoc-Reihenfolge keine
noch nicht persistierte `connection-info.json` voraussetzen. Bevorzugte
Richtung: `Install-LabSampleDatabase` löst nur dann über den Run auf, wenn
das Ziel nicht explizit übergeben wurde; `-RunId` bleibt für RunDirectory
und Journal nutzbar. Alternativen: `connection-info.json` direkt nach der
SQL-Bereitschaft schreiben und am Ende aktualisieren, oder `-RunId` am
Aufruf entfernen (verliert den Run-Bezug in Trust und Journal).

Nachweis bei der Umsetzung: funktionaler Test in der Adhoc-Reihenfolge
(RunId ohne vorhandene `connection-info.json`) inklusive Gegenbeweis;
betroffene Suites `Tests/Static/Invoke-SampleHandlerChecks.ps1` und
`Tests/Static/Invoke-SampleBaselineRuntimeChecks.ps1`; eine reale
Adhoc-Erstellung mit Sample endet in `RUNNING`. Lokale Runtime- und
Diagnosedaten werden nur als beschriebener Ist-Zustand referenziert und
nicht versioniert.

Nicht-Ziele: kein geänderter `Resolve-LabRunInstance`-Vertrag für
Laufzeit-Cmdlets und kein Redesign des Provisioning-Kerns.

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
