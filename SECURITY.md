# Security Policy

## Zweck

`SQL_Server_Lab` erzeugt lokale SQL-Server-Testumgebungen und verarbeitet dabei Passwörter, lokale Pfade, Containerinformationen, Datenbankartefakte und Laufzeit-State. Sicherheitsmeldungen müssen deshalb so erfolgen, dass keine zusätzlichen Secrets oder realen Daten veröffentlicht werden.

## Unterstützter Bereich

Sicherheitsrelevant sind insbesondere:

- unbeabsichtigte Offenlegung von SA-Passwörtern oder anderen Secrets;
- Zugriff auf Container, State oder Dateien außerhalb des zugehörigen Lab-Scopes;
- unsichere Pfadbehandlung;
- unkontrolliertes Löschen fremder Container, Volumes oder Dateien;
- Command-, SQL- oder Argument-Injection;
- unsichere Downloads oder fehlende Integritätsprüfung;
- Persistenz sensibler Runtimewerte in Git, Logs oder Pull-Request-Artefakten.

## Meldung

Verwenden Sie bevorzugt GitHubs private Vulnerability-Reporting-Funktion des Repositories, sofern sie in der Repository-Oberfläche angeboten wird.

Falls kein privater Meldeweg verfügbar ist:

1. Erstellen Sie ein öffentliches Issue mit einer knappen Beschreibung, dass ein potenzielles Sicherheitsproblem vorliegt.
2. Veröffentlichen Sie keine Exploitdetails, Secrets, realen Hostdaten, Kundendaten oder verwertbaren Diagnoseausgaben.
3. Bitten Sie um einen privaten Kommunikationsweg für die technischen Details.

Es wird keine E-Mail-Adresse erfunden oder vorausgesetzt, die nicht ausdrücklich im Repository als Security-Kontakt veröffentlicht wurde.

## Nicht in Meldungen aufnehmen

- Passwörter oder Tokens
- reale Connection Strings
- vollständige `run-state.json`, `connection-info.json` oder Secret-Dateien
- Produktionsbackups oder reale Datenbankinhalte
- interne Hostnamen, öffentliche IP-Adressen oder Benutzerpfade
- Kundennamen oder personenbezogene Daten

Reduzieren Sie Nachweise auf ein synthetisches Minimalbeispiel.

## Erwartete Angaben

Eine belastbare Meldung enthält nach Möglichkeit:

- betroffene Datei, Funktion oder Version;
- Voraussetzungen zur Reproduktion;
- minimale synthetische Reproduktionsschritte;
- erwartetes und tatsächliches Verhalten;
- potenzielle Auswirkung;
- Information, ob Docker, Podman oder ein anderer Pfad betroffen ist;
- Hinweis, welche sensiblen Details absichtlich nicht öffentlich beigefügt wurden.

## Reaktion und Veröffentlichung

Sicherheitsprobleme werden zunächst reproduziert und hinsichtlich Scope, Datenexposition, Destruktivität und Wiederherstellbarkeit bewertet. Eine öffentliche technische Beschreibung erfolgt erst, nachdem eine Korrektur oder ausreichende Schutzmaßnahme verfügbar ist.

## Sicherheitsgrenzen des Projekts

Das Projekt ist für isolierte Test- und Labumgebungen bestimmt. Es ist kein Produktions-Orchestrator und keine Secret-Management-Plattform.

Produktionsbackups, unbekannte Datenartefakte und reale Kundendaten sind nicht zulässig. Bekannte funktionale Grenzen stehen in `Documentation/Quality/KNOWN_LIMITATIONS.md`.
