# Verbindliche Arbeitsregeln

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-07-26 |

## 1. Scope

- SQL Server ist Hauptzweck jeder Funktion und jedes Packages.
- Supporting Components sind nur mit dokumentiertem SQL-Bezug zulässig.
- Hyper-V, Docker und Podman sind gleichrangige Kernprovider.
- Keine allgemeine Nicht-SQL-Labplattform entwickeln.

## 2. Änderungen

Vor jeder Änderung:

1. aktuellen `main`-Stand prüfen;
2. Zielpfad und Verantwortungsgrenze prüfen;
3. Privacy- und Secret-Risiko prüfen;
4. vorhandene Contracts und Entscheidungen lesen;
5. nur beabsichtigte Dateien ändern;
6. Statuswahrheit beibehalten.

## 3. Datenschutz

- keine realen Personen-, Firmen-, Kunden-, Organisations- oder Umgebungsdaten;
- keine realen Hostnamen, IP-Adressen, Pfade, Endpunkte oder Datenbankstrukturen;
- keine Secrets, Tokens, Connection Strings oder private Schlüssel;
- keine realen Logs, Plans, Screenshots oder Responses;
- ausschließlich synthetische Beispiele;
- lokale Runtimewerte nicht in Repositoryartefakte übernehmen;
- bei Zweifel stoppen und nicht sensitive Alternative wählen.

## 4. Providerlogik

- Providerbefehle gehören ausschließlich in Provideradapter.
- Project Packages enthalten keine direkten Docker-, Podman- oder Hyper-V-Löschbefehle.
- Docker-Tests gelten nicht automatisch für Podman.
- Hyper-V-Planung gilt nicht als Runtime-Nachweis.
- tatsächliche Ressourcen-IDs werden im lokalen State registriert.
- keine Wildcard-, Prune- oder Name-only-Löschung.

## 5. Packages

Jedes ausführbare Package benötigt:

- `SqlPurpose`;
- Primary SQL Component;
- versionierte Contracts;
- Deployment Units;
- DataSets, soweit Testdaten erforderlich sind;
- Workflow;
- Probes und Assertions;
- Cleanup;
- Privacy-, Trust- und License-Policy.

Supporting Components benötigen SQL-Begründung und Relation.

## 6. Workflow

- Plan vor Mutation;
- State vor erster Mutation;
- harte Timeouts;
- begrenzte Retries;
- Compensation für mutierende Steps;
- Cleanup nach begonnenem Arrange unabhängig vom Ergebnis;
- Cleanupfehler ergeben `RECOVERY_REQUIRED`;
- `PASS` nur bei erfolgreichem erforderlichem Cleanup.

## 7. Secrets

- nur Secret References in Contracts;
- keine Secretwerte in Logs, Events, Plans oder Evidence;
- keine funktionsfähigen Beispielpasswörter;
- lokale Secretdateien nur unter ignoriertem Run Scope;
- restriktive Dateirechte;
- Cleanup entfernt temporäre Secretdateien.

## 8. Dokumentation

- Deutsch;
- etablierte englische Fachbegriffe;
- vollständige Sätze;
- dokumentiert, empirisch, Entscheidung oder Vermutung klar unterscheiden;
- SQL-Version, Provider und Capability-Grenze nennen;
- geplante Commands nicht als implementiert darstellen;
- Supporting Technologies immer über SQL-Zweck erklären.

## 9. Validierung

Mindestens passende lokale Prüfungen ausführen:

- Static;
- Contract;
- Planner;
- Synthetic Provider;
- Native Runtime, wenn Providerfunktion betroffen ist;
- Privacy;
- Documentation Links;
- Cleanup und Fremdobjektschutz.

CI/CD ist keine Voraussetzung und gehört in ein mögliches separates Repository.

## 10. Migration

- kein Quellartefakt ungeprüft kopieren;
- Funktion, Contract und Zielverantwortung zuerst klassifizieren;
- Analyze- und Schulungsfachlogik bleibt im jeweiligen Projektpackage;
- generischer Lifecycle wird nicht parallel weiterentwickelt;
- alte Pfade erst nach Paritätsnachweis entfernen;
- Compatibility Wrapper während der Übergangsphase.

## 11. Drittanbieter

- bestehende Projekte als Muster oder optionale Backends prüfen;
- keine neue verpflichtende Abhängigkeit ohne Lizenz-, Security-, Maintenance- und Exit-Review;
- AutomatedLab nur als möglicher Hyper-V-Backendadapter;
- keine Lösung über alle untersuchten Produkte zusammensetzen;
- eigener öffentlicher Lab Contract bleibt maßgeblich.

## 12. Git

- keine Force-Pushes;
- keine unabsichtlichen Änderungen außerhalb des Scopes;
- Branches nach Abschluss mergen oder löschen;
- Commit- und PR-Beschreibung nennen Scope und Validierung;
- keine Runtime-, Secret-, Cache- oder Evidence-Rohdaten committen.
