# Befristeter erhöhter Runner für die native Windows-TLS-Abnahme

## Auftrag und Grenze

Der Benutzer hat am 2026-11-04 die Einrichtung eines begrenzten erhöhten Runners
und den autonomen Abschluss des nativen Consumer-Gesamtfalls freigegeben.
Dieser Runner ist ein Operatorwerkzeug für genau diesen SQL-Lab-Vertrag,
kein allgemeiner Befehlsdienst. Der
[Werkzeugeinstieg](../../Tools/BoundedTlsRunner/README.md) führt durch Vorbereitung,
einmalige erhöhte Installation und anschließende Anforderungen ohne Erhöhung.

Eine neue Lease erlaubt höchstens zwei serielle Windows-/Hyper-V-/SQL-2025-RTM-
Erstellungen in zwei Stunden, je Versuch höchstens 45 Minuten. Frühere Wellen,
Fehler und Verbräuche bleiben erhalten. Das Datenroot, die bestehende Authority,
CA, Clientreferenz und der registrierte Windows-Paketkontext sind vorab gebunden.
Es gibt keinen Provider-, Trust-, Identitäts- oder Ziel-Fallback.

## Ausführung und Rechte

Die Installation benötigt einen bereits erhöhten Prozess derselben registrierten
Lab-Identität. Die eigene Windows-Aufgabe verwendet `InteractiveToken` und
`Highest`; es wird kein Kennwort gespeichert, kein Systemaccount verwendet und
kein allgemeiner Autostart eingerichtet. Die Benutzeranmeldung muss fortbestehen;
physische Anwesenheit während der Lease ist nicht erforderlich.

Aufgabe, Datenmanifest und ausführbare Quellen liegen in einem eigenen
administrativ geschützten CommonApplicationData-Verzeichnis. Die Quelle wird
beim Installieren aus denselben geprüften Bytes kopiert und vor Ausführung erneut
gebunden. Die gewöhnliche Identität erhält an der Aufgabe ausschließlich Lesen
und Ausführen, keine Änderungsrechte. Die DACL wird bei Registrierung atomar
gesetzt. Pfade, Quellinventar, Binaryhashes und der eigene Aufgabenname bleiben
gebunden. Git-Konfiguration, Modulpfade und relevante Prozessumgebung werden
ausschließlich im eigenen Prozess isoliert.

Requests enthalten nur Vertragsversion, Runner-ID, Request-ID und eine der drei
Operationen `Ready`, `Run`, `Close`. Doppelte JSON-Felder, zusätzliche Eigenschaften,
Quellpfadausbrüche, unbekannte Operationen, Replay, abgelaufene Leases und
erschöpfte Zähler werden abgewiesen. Requests dürfen keine Befehle, Skriptpfade,
SQL-Texte, Laufzeitverlängerungen oder frei wählbaren Zielparameter enthalten.

Private Arbeitsdaten benötigen weiterhin die CurrentUser-/SYSTEM-DACL des
bestehenden TLS-Vertrags. Eine hohe Mandatory-Integrity-Kennzeichnung mit
No-Write-Up verhindert zusätzlich Änderungen aus dem gewöhnlichen Prozess.
Das Requestverzeichnis ist getrennt beschreibbar; sein administrativer Besitzer
und Parent bleiben geschützt. Die eigentlichen Negativnachweise für Quellen-,
Ergebnis- und Aufgabenrechte sind native Installations-/Abnahmegates.

Die zugrunde liegenden Windowsmechanismen beschreibt Microsoft unter
[Task-Sicherheitskontexten](https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks)
und [Mandatory Integrity Control](https://learn.microsoft.com/en-us/windows/win32/secauthz/mandatory-integrity-control).
Dies ist kein Schutz gegen einen bereits voll berechtigten Administrator.

## Fachlicher Ablauf und Ende

Der feste Workflow verwendet den bestehenden registrierten Paketkontext über
den regulären Windows-Debugstarter. Alle Capability-/Authorityprüfungen bleiben
erforderlich; der Starter allein qualifiziert weder Token noch TLS.
Der [Windows-TLS-Vertrag](AUTHENTICATED_TLS_WINDOWS_OPERATIONAL_LAB.md) bleibt
unverändert. Die Abnahme umfasst einen ununterbrochenen öffentlichen Neuaufbau,
beide strikten Clientstacks, neuen signierten V2-Export, beide Readerpfade,
zusätzliche SQL-Consumer-Anmeldung, öffentlichen eigenen Remove und den
regulären separaten Koordinatoraudit.

Bei einem bestätigten fehlgeschlagenen, vollständig bereinigten Versuch darf ein
weiterer begründeter Request innerhalb der ursprünglichen Grenzen folgen.
Ein unveränderter Fehlversuch wird nicht blind wiederholt. Unbekanntes
Verbraucherende sperrt weitere Versuche und erhält die eigenen Ressourcen.
Zeitablauf stoppt neue Arbeit und erzwingt kein Kill laufender Gastoperationen.
Nur erforderliche sichere Abschluss-/Cleanupschritte dürfen danach weiterlaufen.

Bei PASS, ausdrücklichem Close oder Leaseablauf wird ausschließlich die exakt
gebundene eigene Aufgabe entfernt. Private Nachweise und die gebundene
Quellkopie bleiben zur Diagnose erhalten; ihre Existenz ist kein aktiver
Administratorzugang. Fremde Aufgaben, VMs, Switches, Images, Trust und
Verbraucher werden nicht geändert. Kein Release und kein Tag werden erzeugt.

## Validierungsstand

Die [fokussierte Suite](../../Tests/Static/Invoke-BoundedTlsRunnerChecks.ps1)
prüft die geschlossenen Protokoll-, Pfad-, Budget- und Quellenverträge sowie
die tatsächliche Consumer-Vorbereitung ohne SQL-Anmeldung. Schedulerrechte,
hohe Dateilabels, Paketkontext, autonomer Start und das native Gesamtergebnis
benötigen getrennte reale Nachweise. Der [native Abschlussnachweis](../Quality/BOUNDED_WINDOWS_TLS_RUNNER_ACCEPTANCE_2026-11-04.md) belegt 14 Sicherheitsprüfungen und alle sieben Koordinatorabschnitte PASS; eigene Aufgabe, VM und Export sind entfernt. Ein real abgewarteter Leaseablauf bleibt separat. Der
[vorherige Teilnachweis](../Quality/TLS_WINDOWS_PUBLIC_CREATE_ACCEPTANCE_2026-11-04.md)
bleibt unverändert: öffentlicher Aufbau bestanden, damaliger Gesamtfall FAIL.
