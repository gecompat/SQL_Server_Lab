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

### 5. Kuratierte Kontexthilfe deckt nur den kritischen Pfad ab

Der Hilfekatalog führt 19 Bildschirme. Die Oberfläche verwendet deutlich mehr
`ScreenId`-Werte. Nicht kuratierte Bildschirme liefern eine ehrliche generische
Auskunft; sie nennen aber weder Zweck noch Folgewirkung noch Voraussetzungen.

### 6. Statusband nur auf zwei Bildschirmen

`main-menu` und `queue-menu` reservieren ein Statusband. Für langlaufende
Vorgänge, die aus anderen Bildschirmen gestartet werden, fehlt die Rückmeldung.

### 7. Secret-Referenz bestehender Composer-Positionen

Der Composer setzt die Referenz auf eine `SQL_SERVER_LAB_SECRET_*`-Variable beim
Anlegen einer Position. Für bereits gespeicherte Positionen ohne Referenz fehlt
ein Nachpflegeweg; sie bleiben im Preflight blockiert.

### 8. Weitere flache Bereichsmenüs

| Menü | Einträge ohne `Zurueck` |
|---|---|
| `infrastructure-menu` | 2 |
| `settings-menu` | 3 |
| `hyperv-menu` | 4 |
| `database-menu` | 5 |

`infrastructure-menu` delegiert ausschließlich an zwei Unterbereiche und trägt
keine eigene Handlung.

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
