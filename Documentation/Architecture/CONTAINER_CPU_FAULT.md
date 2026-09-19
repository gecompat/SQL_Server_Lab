# Interner Container-CPU-Puls

Der eng begrenzte FLT-811/FLT-812-Slice in `Private/ContainerCpuFault.ps1`
führt das feste Profil `container.cpu-limit` auf einem frischen, laufenden,
operationseigenen SQL-Testcontainer aus: zwei CPUs werden vorübergehend auf
eine CPU begrenzt. Es gibt keine öffentliche API und keine freien Commands,
Scriptblocks, SQL-Texte, Endpunkte oder weiteren Fault-Profile. SCN-801 und
SCN-802 bleiben eigenständig und unverändert. Der allgemeine Container-
Reconcile und `Update-SqlServerLabContainer` werden nicht verwendet.

Der vertrauenswürdige interne Aufrufer erzeugt vor der Provisionierung eine
neue Operation-ID und setzt die bestehenden Lifecycle-Testlabels. Das Ziel
bindet diese Operation an die vollständige Container-ID, Run-, Scope- und
Instanz-ID, Provider und frühesten Erstellungszeitpunkt. Der Container muss
nach diesem Zeitpunkt und innerhalb eines 30-Minuten-Fensters erstellt worden
sein. Die Runtime muss sämtliche Labels einschließlich `lifecycle=test` und
`test-operation-id` bestätigen. Schutz-, Reservierungs-, Umgebungsgruppen-
und Supporting-Labels werden abgewiesen. Bestehende fremde Container,
unbegrenzte, widersprüchliche und nicht exakt unterstützte CPU-Konfigurationen
werden nicht übernommen. Die Anwendung liest keine globale Run-Inventur.

Der Slice pinnt einen lokalen Docker-Endpunkt oder eine lokale Podman-
Connection einschließlich SSH-Identity. Remote-Endpunkte und unbekannte
Konstellationen bleiben ausgeschlossen. Jeder native Aufruf verwendet diese
Bindung und bereinigt konfliktfähige Prozess-Overrides. Die Runtimeidentität
wird vor Aktivierung und Wiederherstellung erneut geprüft. SQL-Probes laufen
im exakt gebundenen Container über den festen `mssql-tools18`-Pfad und prüfen
SQL Engine Edition sowie den ONLINE-Zustand von `master`. Das Passwort lebt
nur im Prozesskontext, nicht in CLI-Argumenten oder Journal. SQL-Versionen
ohne diesen Tools-Pfad sind nicht unterstützt.
Die feste Inspect-Projektion liest nur Identität, Laufzustand, Labels und
Hostkonfiguration; `Config.Env` mit möglichen SA-Secrets wird nicht abgefragt.

Unterstützte Rohzustände sind `NanoCpus=2000000000` bei unverändertem
Null-Period-/Quota-Paar oder `CpuPeriod=100000, CpuQuota=200000` ohne Nano-Cap.
Podman darf zusätzlich genau die konsistente `NanoCpus=2000000000`-Projektion
dieses Quota-Paars melden; diese projektionseigene Form wurde am frischen
nativen Podman-Testcontainer beobachtet. Abweichende Kombinationen werden
nicht als gleichwertig angenähert.
Weitere aktive CPU-Limits und CPU-Sets werden abgewiesen. Alle zehn gelesenen
CPU-Felder bleiben einschließlich Nullwerten im lokalen Baseline-Journal.
Die Mutation setzt ausschließlich das CPU-Limit; Wiederherstellung und
Postcondition vergleichen exakt die gespeicherten Rohfelder sowie Container-
Erstellungszeitpunkt und Image-ID.

Vor Aktivierung wird die Baseline zusammen mit dem festen Restore-Intent
atomar veröffentlicht: eigene temporäre Datei, Flush, Rename und exklusiver
Operationslock. HMAC-SHA-256 authentifiziert den vollständigen Inhalt mit
einem vom Aufrufer geschützten 32-Byte-Schlüssel. Schema, Zielhash und
Ownership werden vor Cleanup erneut geprüft. Der Aufrufer hält Schlüssel und
lokales Journalverzeichnis außerhalb der Versionsverwaltung. Ohne denselben
Schlüssel ist automatisches Resume nicht zulässig. Dies ist keine Sandbox
gegen einen Angreifer mit gleichwertigem lokalem Zugriff oder Schlüssel und
kein Schutz gegen Replay früherer authentifizierter Journale.

Unmittelbar nach erfolgreicher nativer Applied-Postcondition wird
`AppliedVerified=true` erneut atomar und authentifiziert gespeichert, noch
vor der SQL-Beobachtung und vor `finally`. Der Checkpoint erhält den exakten
Ausgangszustand, `PrimaryStatus=NOT_EXECUTED` und null Cleanupversuche; Resume
rekonstruiert daraus die Baseline und markiert den Primärlauf `INTERRUPTED`.

Die Aktivierung, Applied-Postcondition und feste SQL-Beobachtung verwenden
jeweils höchstens eine Sekunde native Wartezeit. Es gibt keine zusätzliche
Haltephase; danach beginnt unmittelbar der `finally`-Restore. Nur die privaten
Abbruchfixtures aktivieren nach dem dauerhaften Checkpoint eine feste,
auf 30 Sekunden begrenzte Synchronisationspause. Zielvertrag, Umgebung und
öffentliche API bieten dafür keinen Eingabeparameter. Fünf Sekunden
sind die Arbeitsdeadline des Pulses, keine Garantie bei Host-/Runtimeausfall,
blockierendem Dateisystem oder hartem Prozessabbruch. Wiederherstellung hat
eigene begrenzte native Aufrufe und maximal drei dauerhaft gezählte Versuche.
Ein abgebrochener CLI-Prozess beweist keine Abbruchbestätigung der Engine.
Nicht bestätigte Wiederherstellung bleibt `RECOVERY_REQUIRED`.

Cancellation vor dem frischen Aufruf erzeugt weder Dateien noch Mutation.
Cancellation nach Aktivierung fordert Wiederherstellung an. Primärstatus,
Applied- und Restore-Evidence und Cleanupstatus bleiben getrennt. Resume
führt ausschließlich Restore aus, auch wenn der Prozess bereits direkt nach
dem Write-ahead-Journal starb; Aktivierung wird niemals wiederholt. Ein
unterbrochener Primärlauf bleibt `INTERRUPTED`. Abgeschlossene Journale bleiben
bei erneutem Resume bytegleich. Journalmanipulation blockiert Mutation.

Die Offline-Suite verwendet einen Fake-Provider und einen tatsächlich hart
beendeten eigenen PowerShell-Kindprozess. Der native Runner erstellt über
`New-SqlServerLab` genau einen SQL-2025-Test-Run in einem eigenen State-Root,
prüft Apply, SQL-Beobachtung, exakte Wiederherstellung und terminales Resume
und entfernt anschließend ausschließlich seinen eigenen Run. Bei
Cleanupfehlern bleiben die lokalen Recovery-Dateien erhalten. Native
Docker-/Podman-Abnahmen sind getrennt auszuführen. Beide lokalen SQL-2025-
Läufe bestanden am 2026-09-19 einschließlich Applied-Postcondition, fester
SQL-Beobachtung, exakter Rücknahme, terminalem Resume und vollständigem
Cleanup von jeweils Container und Volume (zwei Schritte, null Fehler).
Die Podman-Vorprüfung wies zunächst dessen projiziertes Nano-/Quota-Tupel
als unbekannt ab; beide Diagnoseversuche blieben mutationsfrei hinsichtlich
des CPU-Pulses und entfernten sämtliche eigenen Runtimeobjekte. Der danach
explizit implementierte Providerfall bestand die native Abnahme. Docker-
Evidence wurde nicht als Podman-Nachweis verwendet.

Der optionale Acceptance-Schalter `-HardInterrupt` erzeugt ebenfalls genau
einen frischen eigenen Run. Der Parent prüft SQL vorab; das Kind erhält nur
Ziel, Operationsschlüssel und temporäres Journalverzeichnis sowie einen lokal
erzeugten Dummy-`SecureString`. Ausschließlich die SQL-Vorprüfung im Kind ist
eine Fixture; native CPU-Aufrufe, Ownership und Journal bleiben unverändert.
Der Parent wartet auf den authentifizierten Applied-Checkpoint, beendet das
Kind hart, bestätigt dessen Ende und prüft den weiterhin aktiven CPU-Puls.
Erst danach führt er Resume mit dem echten SA-Secret aus. Erwartet werden
`INTERRUPTED`, `CleanupStatus=PASSED`, alle zehn exakten CPU-Rohfelder samt
Identität, eine native SQL-Probe und keine erneute Aktivierung. Ein zweites
Resume muss das Journal bytegleich erhalten und darf keine weitere
CPU-Mutation oder SQL-Probe auslösen. Cleanup verlangt den erfolgreichen
Run-Abschluss sowie fehlende eigene Container und Volumes.

Die getrennten lokalen `-HardInterrupt`-Läufe für Docker und Podman bestanden
am 2026-09-19 sämtliche dieser Postconditions einschließlich vollständigem
Cleanup von jeweils Container und Volume (zwei Schritte, null Fehler) und
temporären Recovery-Dateien. Der erste Podman-Abbruchtest scheiterte bereits
vor Aktivierung an der Inspect-Template-ID und bereinigte vollständig. Der
feste Podman-Ausdruck `{{json .ID}}` korrigiert diese Abweichung; der anschließende
native Lauf bestand. Die Offline-Suite prüft denselben Applied-Checkpoint
für beide Providerformen mit einem tatsächlich hart beendeten Kindprozess.

Weitere SQL-Versionen, Host-/Engine-Abstürze und Unterbrechungen an anderen
nativen Zeitpunkten bleiben `NOT_EXECUTED`. Hyper-V, weitere Fault-Klassen und die allgemeine Scenario-
Integration sind nicht Teil dieses Slice. Ein bestandener Puls belegt keine
fachliche Performanceverschlechterung oder allgemeine Fault-Plattform.
