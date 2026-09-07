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

## Offene Punkte

### 1. Nächtliche Regression auf `main`

Der Workflow `Nightly Regression` schlägt seit mindestens 2026-09-03 durchgehend
fehl. Betroffen sind ausschließlich zwei Runtime-Jobs; alle statischen Suiten
sind grün.

| Job | Ergebnis |
|---|---|
| `docker-runtime / Docker provider runtime / CLI acceptance` | `failure`, Schritt `Docker SQL Server lifecycle / CLI acceptance`, Abbruch mit `Process completed with exit code -1` ohne verwertbare Meldung |
| `hyperv-runtime / Hyper-V lifecycle, isolated OS-slot batch, or shared environments` | `failure` |

Der zuletzt ausgewertete Lauf lag auf einem Commit vor den Änderungen vom
2026-09-07. Ob der aktuelle Stand daran etwas ändert, ist unbelegt.

Zu klären:

- War `docker-runtime` jemals grün, oder bricht der Job seit seiner Einführung?
- Ist `exit code -1` ein Infrastrukturabbruch des Runners oder ein Fehler im Skript?
- Erwartet `hyperv-runtime` verschachteltes Hyper-V, das ein GitHub-Runner nicht bietet? Dann gehört der Job als nicht ausführbar gekennzeichnet statt dauerhaft rot.

Der PR-Gate umfasst diese Runtime-Jobs nicht. Ein dauerhaft roter Nightly-Lauf
entwertet das Signal für alle folgenden Änderungen.

### 2. Datenbankmenü ist unvollständig

`database-menu` bietet fünf Einträge. Mehrere vorhandene öffentliche Funktionen
sind aus der Oberfläche nicht erreichbar, weil kein `Invoke-LabAction`-Fall
existiert. Das ist echte Neuarbeit, kein Verdrahten von Vorhandenem.

| Funktion | Zweck |
|---|---|
| `Backup-SqlServerLabDatabase` | Datenbank sichern |
| `Restore-SqlServerLabDatabase` | Datenbank wiederherstellen |
| `Export-SqlServerLabDatabasePackage` | Paket exportieren |
| `Invoke-SqlServerLabDatabasePackageAttach` | Paket anhängen |
| `Get-SqlServerLabDatabasePackage` | Pakete auflisten |
| `Get-SqlServerLabDatabaseMigrationDependency` | Migrationsabhängigkeiten prüfen |

Der Anti-Waisen-Vertrag greift hier nicht, weil diese Funktionen nicht in der
`ValidateSet` stehen. Er verhindert nur, dass eine angebotene Aktion unerreichbar
wird, nicht dass eine Fähigkeit gar nicht erst angeboten wird.

### 3. Provider-Diagnoselog deckt nur die Containererstellung ab

`Write-LabProviderLog` wird ausschließlich im Schritt `container-create` von
Docker und Podman aufgerufen. Nicht abgedeckt sind Start, Stopp, Volume-,
Image-Build- und Hyper-V-Operationen. Es fehlen ein gemeinsamer Aufrufwrapper und
eine Rotation, damit der Logpfad nicht unbegrenzt wächst.

### 4. Begründung deaktivierter Einträge ist unvollständig

`environment-menu` und `queue-menu` begründen jeden deaktivierten Eintrag. Für die
übrigen Bildschirme fehlt `-DisabledReason` überwiegend. Ohne statische Pflicht
entstehen jederzeit neue Einträge ohne Begründung.

Vorschlag: Eine Prüfung, die jeden `-Disabled`-Eintrag ohne `-DisabledReason`
meldet, analog zur bestehenden Anti-Waisen-Prüfung.

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

Die Reihenfolge ist nicht festgelegt. Punkt 1 hat den höchsten Wert, weil ein
dauerhaft roter Nightly-Lauf jede spätere Regression verdeckt. Punkt 2 ist der
größte fachliche Zugewinn, erfordert aber neue interaktive Pfade und damit einen
eigenen Änderungssatz je Funktion.

Für Reihenfolge und Priorität gegenüber anderen Vorhaben bleibt
`DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md` maßgeblich.
