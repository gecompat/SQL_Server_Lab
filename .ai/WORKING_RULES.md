# Verbindliche Arbeitsregeln

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-07-28 |

## 1. Scope

- SQL Server ist Hauptzweck jeder Funktion und jedes zukünftigen Packages.
- Supporting Components sind nur mit dokumentiertem SQL-Bezug zulässig.
- Docker und Podman sind aktuell implementierte Kernprovider.
- Hyper-V besitzt eine isolierte Lifecycle-Grundlage, ist aber noch kein SQL-fertiger Runtimeprovider.
- Keine allgemeine Nicht-SQL-Labplattform entwickeln.

## 2. Vor jeder Änderung

1. Root-`AGENTS.md` lesen;
2. aktuellen `main`-Stand prüfen;
3. offene Branches und Pull Requests auf Überschneidungen prüfen;
4. Zielpfad und Verantwortungsgrenze bestimmen;
5. Privacy- und Secret-Risiko prüfen;
6. autoritative Quellen aus `.ai/repo_map.yaml` lesen;
7. `MODEL_ROUTING_POLICY.md` und
   `Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md` anwenden;
8. bekannte Grenzen prüfen;
9. nur beabsichtigte Dateien ändern;
10. gekoppelte Dokumente und Tests mitführen;
11. Statuswahrheit beibehalten.

## 3. Datenschutz

- keine realen Personen-, Firmen-, Kunden-, Organisations- oder Umgebungsdaten;
- keine nicht freigegebenen Hostnamen, öffentlichen IP-Adressen, Pfade oder Endpunkte;
- keine realen Datenbankstrukturen aus Produktivsystemen;
- keine Secrets, Tokens, privaten Schlüssel oder Connection Strings mit Passwörtern;
- keine realen Logs, Plans, Screenshots oder Responses;
- ausschließlich synthetische Testbeispiele oder dokumentierte öffentliche Samples;
- lokale Runtimewerte nicht in Repositoryartefakte übernehmen;
- bei Zweifel vor dem Schreiben oder Git-Vorgang anhalten.

Bereits ausdrücklich freigegebene Projekt- und Attributionseinträge dürfen unverändert erhalten bleiben.

## 4. Öffentliche API

- `SqlServerLab.psd1` ist die autoritative Exportliste.
- Nicht implementierte Funktionen dürfen nicht exportiert werden.
- Jede exportierte Funktion benötigt comment-based Help und Benutzerreferenz.
- Interne Hilfsfunktionen werden nicht als direkte Benutzer-API dokumentiert.
- Änderung von Parametern, Rückgabeobjekten oder Seiteneffekten erfordert Doku- und Testanpassung.

## 5. Manifestvertrag

Ein Manifestfeld ist erst implementiert, wenn alle Ebenen übereinstimmen:

1. `Schemas/lab-manifest.schema.json`;
2. `Private/ManifestParser.ps1`;
3. zuständige Runtimefunktion;
4. ausführbares Beispiel;
5. Dokumentation und Known Limitations;
6. passende Prüfung.

Ein Schemaeintrag allein ist kein Runtime-Nachweis.

Relative Pfade müssen zentral und nachvollziehbar aufgelöst werden. Unbekannte Formate oder Quellen werden mit einer klaren Meldung abgelehnt und nicht erraten.

## 6. Providerlogik

- Provider-spezifische Provisionierung und spezielle Operationen gehören in den Provideradapter.
- Gemeinsame Docker-kompatible Lifecycleoperationen dürfen zentral ausgeführt werden, müssen aber den im Run gespeicherten Provider verwenden.
- Ein globaler Auto-Detect darf keine bestehende Providerbindung überschreiben.
- Docker-Tests gelten nicht automatisch für Podman.
- Nur der eigene Hyper-V-Native-Smoke-Test gilt als Lifecycle-Nachweis; Planung und statische Checks sind kein Runtime-Nachweis.
- Ein Providerverzeichnis allein bedeutet nicht, dass der Provider implementiert ist.
- Gemischte Provider in einem Run werden bis zu einem eigenen Vertrag ausdrücklich abgelehnt.
- tatsächliche Ressourceninformationen werden im lokalen State registriert.
- keine ungebundene Wildcard-, Prune- oder Name-only-Löschung.

## 7. Versionen und Kataloge

- SQL-Versionen und Builds werden aus Katalogen aufgelöst.
- Unbekannte CU-Bezeichner oder Image-Tags werden nicht erfunden.
- Katalogeinträge benötigen Schema, Auflösungslogik und fachliche Verifikation.
- Neue Produktjahre werden nicht durch Code-Duplikation ergänzt.
- Ein Katalogeintrag wird nicht automatisch als aktuellster Herstellerstand bezeichnet.
- Sample-Einträge benötigen Quelle, Lizenz, Variante und Mindestversion.

## 8. Datenbankartefakte

Zulässig:

- synthetische Labdaten;
- öffentliche Demo-Datenbanken mit dokumentierter Quelle und Lizenz;
- ausdrücklich klassifizierte lokale Nicht-Produktionsbackups.

Unzulässig:

- Produktionsbackups;
- reale Produktivdaten;
- unbekannte oder unklassifizierte Artefakte;
- automatische Übernahme lokaler Backups in Git oder Downloadartefakte.

Restore, Attach, Archiv, SQL-Skript und Backupkette sind unterschiedliche Verträge und dürfen nicht stillschweigend ineinander umgedeutet werden.

## 9. Workflow und Cleanup

- State vor erster Mutation;
- Cleanup-Plan vor erster Provider-Mutation;
- harte Timeouts;
- begrenzte Retries;
- Compensation für mutierende Schritte;
- Cleanup nach begonnenem Arrange unabhängig vom Ergebnis;
- Cleanupfehler ergeben einen sichtbaren Recoverybedarf;
- `PASS` nur bei erfolgreichem erforderlichem Cleanup oder bewusst persistentem Endzustand;
- Fehlerursache und Cleanupstatus werden getrennt erhalten.

## 10. Secrets

- keine Secretwerte in Logs, Events, Plans, Doku oder Evidence;
- synthetische Testpasswörter sind nur in ausdrücklich lokalen Testskripten zulässig;
- synthetische Testpasswörter dürfen nicht als produktionsgeeignete Beispiele dargestellt werden;
- Klartextkonvertierung nur so kurz wie technisch erforderlich;
- unmanaged Secretbuffer nach Möglichkeit explizit freigeben;
- lokale Secretdateien nur unter ignoriertem Run-Scope;
- Cleanup entfernt temporäre Secretdateien.

## 11. Sprachstil, Dokumentation und Übersetzungen

- Primärsprache der aktiven Projektdokumentation ist Deutsch.
- Jedes Dokument und jeder zusammenhängende Text verwendet grundsätzlich eine klare Hauptsprache; unbeabsichtigte Mischsprache ist zu vermeiden.
- Etablierte englische Fachbegriffe bleiben erhalten, wenn eine Übersetzung ungebräuchlich, künstlich oder missverständlich wäre.
- Produktnamen, Programmiersprachen, SQL-Befehle, APIs, Dateinamen, Parameter, Cmdlets, Klassen-, Funktions- und Variablennamen werden nicht übersetzt.
- Gleiche Fachbegriffe werden projektweit konsistent verwendet; keine wechselnden Varianten wie `Provider`/`Anbieter`, `Branch`/`Zweig` oder `Commit`/`Einspielung`.
- Keine neuen technischen Fachbegriffe oder künstlichen Übersetzungen erfinden.
- Bestehende Dokumentation nicht allein wegen ihrer Sprache übersetzen. Übersetzungen nur auf ausdrücklichen Auftrag, zur Behebung eines konkreten Konsistenzproblems oder für ausdrücklich gepflegte Sprachversionen.
- Neue Texte an den Sprachstil des jeweiligen Dokuments anpassen.
- Kommentare im Quellcode folgen der im jeweiligen File vorherrschenden Sprache; bestehende Kommentare nicht ohne fachlichen Grund übersetzen.
- Sachlich, eindeutig, technisch präzise, gut lesbar und möglichst zeitlos formulieren.
- Marketing-Sprache, übertriebene Werbung, unnötige Füllwörter, emotionale Wertungen, Spekulationen und unbegründete Behauptungen vermeiden.
- Aktive Formulierungen bevorzugen, wenn sie klarer sind.
- Vollständige und überprüfbare Sätze verwenden.
- Ist-Stand, Planung, Entscheidung und Vermutung trennen.
- SQL-Version, Provider und Capability-Grenze nennen.
- Geplante Commands nicht als implementiert darstellen.
- Beispiele verwenden keine individuellen Entwicklerpfade.
- Dokumentierte Parameter müssen tatsächlich existieren.
- Code, Befehle, Konfigurationswerte und Beispiele nicht sinngemäß übersetzen oder technisch verändern.
- Relative Links und Dateiverweise müssen funktionieren.
- Supporting Technologies immer über ihren SQL-Zweck erklären.
- Root-README, Getting Started, Known Limitations und Repo-Map bilden gemeinsam die Front Door.
- Artefaktspezifische Sprachkonventionen bleiben erhalten; insbesondere verwendet das Projekt weiterhin englische Commit Messages mit dem vorgeschriebenen KI-Präfix.

## 12. Validierung

Testauswahl, lokale Logauswertung, Wiederholungen und vollständige Gates folgen
dem verbindlichen Vertrag unter
`Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md`. Zuerst werden die
betroffenen Suites lokal bestimmt:

```powershell
$paths = git diff --name-only origin/main...HEAD
.\Tests\Static\Invoke-ImpactedChecks.ps1 -ChangedPath $paths
```

Vollständige Logs bleiben lokal; in einen KI-Kontext gelangen nur
deduplizierte Findings und entscheidungsrelevante Ausschnitte. Ein
unveränderter grüner Test oder eine identische Fehlersignatur wird ohne neue
Evidence nicht erneut ausgeführt.

Mindestens ausführen:

```powershell
.\Tests\Static\Invoke-DocumentationChecks.ps1
```

Bei Runtimeänderungen den betroffenen Provider getrennt testen:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

Nur tatsächlich ausgeführte Prüfungen werden als bestanden bezeichnet. Fehlende Runtime oder fehlendes `sqlcmd` ergibt keinen grünen Nachweis.

CI/CD ist keine Voraussetzung für lokale Produktfunktion. Statische Checks dürfen später schlank automatisiert werden, ohne lokale Runtimefunktion vorzutäuschen.

## 13. Migration und Quell-Snapshots

- kein Quellartefakt ungeprüft in den aktiven Produktpfad kopieren;
- `_QuellRepo/` ist Referenz, nicht öffentliche API;
- Funktion, Contract und Zielverantwortung zuerst klassifizieren;
- Analyze- und Schulungsfachlogik bleibt im jeweiligen Projekt;
- generischer Lifecycle wird nicht parallel in mehreren Repositories weiterentwickelt;
- alte Pfade erst nach Paritätsnachweis entfernen.

## 14. Drittanbieter

- bestehende Projekte als Muster oder optionale Backends prüfen;
- keine verpflichtende Abhängigkeit ohne Lizenz-, Security-, Maintenance- und Exit-Review;
- AutomatedLab nur als möglicher zukünftiger Hyper-V-Backendadapter;
- eigene öffentliche Labverträge bleiben maßgeblich.

## 15. Git und Pull Requests

- keine Force-Pushes;
- keine unabsichtlichen Änderungen außerhalb des Scopes;
- vorhandene parallele PRs respektieren;
- Branches nach Abschluss mergen oder löschen;
- Commit- und PR-Beschreibung nennen Scope, Auswirkungen und Validierung;
- Commit Messages verwenden gemäß Projektkonvention Englisch;
- von einer KI erzeugte Änderungen erhalten in der ersten Zeile der Commit-Nachricht zwingend das Präfix `<KI-Name>: `; die KI verwendet ihre tatsächliche Produkt- oder Agentenbezeichnung, zum Beispiel `ChatGPT:`, `Codex:` oder `Genie:`;
- bei direkten KI-Commits ist ein zusätzlicher mehrzeiliger Commit-Body zulässig; nur die erste Zeile benötigt das Präfix;
- liefert eine KI wegen fehlendem Repositoryzugriff Dateien, Patches oder Downloadartefakte zur manuellen Übernahme, stellt sie zusätzlich eine vollständige einzeilige Commit-Nachricht mit ihrem Präfix in einem separat kopierbaren Textblock bereit;
- ausschließlich von Menschen erstellte Änderungen benötigen kein KI-Präfix;
- keine Runtime-, Secret-, Cache- oder Evidence-Rohdaten committen;
- vor dem Merge den vollständigen Branch-Diff prüfen;
- bei nicht ausgeführten Native-Tests die Einschränkung offen nennen.

## 16. Statuswahrheit

- `implemented`: Code vorhanden und statischer Vertrag konsistent;
- `validated`: relevante Prüfung tatsächlich erfolgreich ausgeführt;
- `planned`: Ziel oder Vertrag ohne vollständigen Runtimepfad;
- `unsupported`: bewusst nicht ausgeführt oder nicht verfügbar;
- Planungsdokumente sind kein Runtime-Nachweis.
