# Befristeter erhöhter Windows-TLS-Runner

Diese Operatorwerkzeuge führen ausschließlich die feste native Abnahme des
öffentlichen Windows-/Hyper-V-/SQL-2025-RTM-TLS-Pfads aus. Sie ersetzen keinen
allgemeinen Administratorzugang und führen keine übergebenen Befehle, Skripte,
SQL-Texte oder frei gewählten Zielsysteme aus.

Der [Architekturvertrag](../../Documentation/Architecture/BOUNDED_WINDOWS_TLS_RUNNER.md)
beschreibt Grenzen, Voraussetzungen, Dateirechte und Recovery. Der bestehende
[Windows-TLS-Vertrag](../../Documentation/Architecture/AUTHENTICATED_TLS_WINDOWS_OPERATIONAL_LAB.md)
bleibt für Erstellung, Authority, V2-Export und Cleanup maßgeblich.

## Ablauf

1. `Prepare.ps1` erstellt ohne Erhöhung eine neue private Kopie der geprüften
   Quellen und einen Manifesthash. Datenroot, bestehende Authority-/Client-/CA-
   Referenzen und der bereits registrierte Paketkontext werden ausdrücklich
   angegeben. Kennwörter werden weder abgefragt noch kopiert.
2. `Install.ps1 -PlanPath $plan.PlanPath -ExpectedPlanSha256 $plan.PlanSha256`
   benötigt einmal einen bereits erhöhten Prozess derselben Identität. Es
   installiert eine quellgebundene Kopie und genau eine befristete Aufgabe.
3. `Request.ps1 -RunnerId $plan.RunnerId -Operation Ready` startet die
   Vorprüfung aus einem gewöhnlichen Prozess. Erst nach `READY` und den
   dokumentierten Schreibschutz-Gegenproben wird `-Operation Run` angefordert.
4. Status und private Nachweise liegen im eigenen Runnerverzeichnis unter dem
   regulären CommonApplicationData-Pfad. Nach erfolgreichem Gesamtfall wird die
   Aufgabe automatisch entfernt. `-Operation Close` schließt einen untätigen
   eigenen Runner ausdrücklich; spätestens der Ablauf der Lease schließt ihn.

Die Aufgabe verwendet den angemeldeten Benutzer mit `InteractiveToken` und
`Highest`, keinen Systemaccount, kein gespeichertes Kennwort und keinen
Boot-Autostart. Die Sitzung muss angemeldet bleiben; eine unbeaufsichtigte
oder gesperrte Sitzung genügt. Es erfolgen weder weitere UAC-Anforderungen
noch ein Abschalten von Sicherheitsfunktionen oder Änderungen an Gruppen,
Zertifikaten und Hosttrust.

Die feste Lease umfasst höchstens zwei Versuche, jeweils höchstens 45 Minuten
und insgesamt zwei Stunden. Ein zweiter Versuch ist kein automatischer Retry:
er benötigt einen neuen begründeten Request nach bestätigt vollständigem Cleanup.
Unbekanntes Ende erhält die eigenen Ressourcen und die unveränderten Fehler;
es löst weder Kill noch blinden VM-Cleanup aus. Ein vollständiges PASS verlangt
den SQL-Consumer, den regulären Koordinatorabschluss und erforderlichen Cleanup.
