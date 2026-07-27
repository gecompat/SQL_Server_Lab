# Verbindliche Arbeitsregeln

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-07-27 |

## 1. Scope

- SQL Server ist Hauptzweck jeder Funktion und jedes zukünftigen Packages.
- Supporting Components sind nur mit dokumentiertem SQL-Bezug zulässig.
- Docker und Podman sind aktuell implementierte Kernprovider.
- Hyper-V ist ein verbindliches Roadmapziel, aber noch kein Runtimeprovider.
- Keine allgemeine Nicht-SQL-Labplattform entwickeln.

## 2. Vor jeder Änderung

1. aktuellen `main`-Stand prüfen;
2. offene Branches und Pull Requests auf Überschneidungen prüfen;
3. Zielpfad und Verantwortungsgrenze bestimmen;
4. Privacy- und Secret-Risiko prüfen;
5. autoritative Quellen aus `.ai/repo_map.yaml` lesen;
6. bekannte Grenzen prüfen;
7. nur beabsichtigte Dateien ändern;
8. gekoppelte Dokumente und Tests mitführen;
9. Statuswahrheit beibehalten.

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
- Hyper-V-Planung gilt nicht als Runtime-Nachweis.
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

## 11. Dokumentation

- Deutsch;
- etablierte englische Fachbegriffe bleiben erhalten;
- vollständige und überprüfbare Sätze;
- Ist-Stand, Planung, Entscheidung und Vermutung trennen;
- SQL-Version, Provider und Capability-Grenze nennen;
- geplante Commands nicht als implementiert darstellen;
- Beispiele verwenden keine individuellen Entwicklerpfade;
- dokumentierte Parameter müssen tatsächlich existieren;
- relative Links und Dateiverweise müssen funktionieren;
- Supporting Technologies immer über ihren SQL-Zweck erklären;
- Root-README, Getting Started, Known Limitations und Repo-Map bilden gemeinsam die Front Door.

## 12. Validierung

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
- keine Runtime-, Secret-, Cache- oder Evidence-Rohdaten committen;
- vor dem Merge den vollständigen Branch-Diff prüfen;
- bei nicht ausgeführten Native-Tests die Einschränkung offen nennen.

## 16. Statuswahrheit

- `implemented`: Code vorhanden und statischer Vertrag konsistent;
- `validated`: relevante Prüfung tatsächlich erfolgreich ausgeführt;
- `planned`: Ziel oder Vertrag ohne vollständigen Runtimepfad;
- `unsupported`: bewusst nicht ausgeführt oder nicht verfügbar;
- Planungsdokumente sind kein Runtime-Nachweis.
