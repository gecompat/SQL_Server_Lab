# CI-Test- und Evidence-Regeln

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-10-19 |
| Scope | Testauswahl, Ergebnisbewertung und mögliche Wiederverwendung von Nachweisen |

Diese Regeln ergänzen die [Kostenrichtlinie](COST_EFFICIENT_DEVELOPMENT.md)
und die [Validierungsstrategie](LOCAL_VALIDATION_STRATEGY.md). Sie verändern
keine Produkt-, Host-, SQL-, Trust-, Upload- oder Löschberechtigung.
Planung einer Wiederverwendung ist kein implementierter Verifikator.

## 1. Risikobasierte Auswahl

`Tools/Get-CiTestSelection.ps1` bestimmt Provider und statische Suites;
`Tools/Get-CiCapabilitySelection.ps1` ergänzt Fähigkeiten und deren
Voraussetzungen. Mehrere geänderte Pfade ergeben die Vereinigung der Prüfungen.
Ein bekannter enger Pfad darf einen unbekannten oder gemeinsam genutzten
Produktpfad nicht verkleinern. Safety-, Privacy-, Ownership-, Recovery- und
Cleanup-Negativfälle bleiben Teil des erforderlichen Vertrags.

| Wirkung der Änderung | Erforderlicher Nachweis |
|---|---|
| Dokumentation oder SQL-freier Hinweis | Betroffene Doku-/Link-/Privacy-Verträge; kein Providerstart allein wegen des Dateinamens. |
| Reine Oberfläche oder Warntext | Betroffene UI-/Confirmation-/Abbruch- und Sicherheitsfälle. Eine Runtime-Ausnahme verlangt belegte Trennung von Seiteneffekten; ein Textdiff in ausführbarem Lifecyclecode genügt nicht. |
| Deterministischer Codec oder reine Planlogik | Offline-/Unit-/Vertragstests und geprüfte Aufrufer; native Grenzen nur bei tatsächlicher Kopplung. |
| Docker-, Podman- oder Hyper-V-spezifisch | Eigener Provider und relevante Fähigkeiten; fremde Provider nur bei belegter gemeinsamer Abhängigkeit. |
| Gemeinsamer Containerpfad | Docker und Podman mit passenden Fähigkeiten; Mixed zusätzlich bei Koexistenz oder Interop. |
| Gemeinsamer Lifecycle-/State-/Cleanup-/Ownership-Pfad | Vollständige risikorelevante Provider-, Recovery- und Negative-Matrix. |
| Selektor oder Testdefinition | Failure-/Vereinigungsfälle und betroffene Consumer; keine automatische Befreiung ausführbarer Harnessänderungen. |
| Unbekannte Produktwirkung oder unvollständige Abhängigkeiten | Bestehender konservativer Fallback oder sichtbare Blockierung; kein erfolgreicher Skip als Ersatz. |
| Release oder ausdrücklich beauftragte Native-Acceptance | Vollständige beanspruchte SQL-/Provider-/Rechte-/Recovery-/Cleanup-Matrix; offene Fälle bleiben sichtbar. |

Die vorhandene Ausnahme für reine Selektorzuordnung verwendet die ausführbare
CiStrategy-Failure-Matrix. Änderungen an gemeinsamer ausführbarer
Workflow-/Runner-/Ownership-Orchestrierung behalten ihre Consumer-Runtime.
Eine Verengung benötigt vorab überprüfte Abhängigkeiten sowie positive,
negative, ähnliche und gemischte Pfadfälle. Keine pauschale Ausnahme für
`Ui/`, `Public/`, Warntexte oder eine Dateierweiterung im Produktcode ergänzen.

Docker, Podman und Hyper-V bleiben getrennte Nachweise. Deklarierter Support,
Readiness, synthetische Prüfung und ausgeführte Native-Qualification sind
verschiedene Aussagen. Der gewöhnliche Hyper-V-VM/VHDX-Lifecycle-Smoke
installiert weder Windows noch SQL und belegt keine entsprechenden Funktionen.
Manuelle Windows-/SQL-/SSISDB-/TLS-/Recovery-Abnahmen behalten ihre eigene
Freigabe. Testauswahl ist keine Freigabe zur Mutation bestehender Umgebungen.

## 2. Prüfprofile und Ergebniswahrheit

PRs prüfen zuerst betroffene statische und Offlineverträge, dann ausgewählte
Provider/Fähigkeiten. Der aktuelle Required Check bleibt verbindlich.
Nightly erkennt auch Host-/Image-/Infrastrukturdrift. Die bestehende tägliche
Regression wird nicht allein wegen unverändertem Git verkleinert; eine andere
Frequenz benötigt dokumentierte Risiko-, Abdeckungs- und Releasebewertung.
Release und Spezialabnahme behalten ihre vollständigen eigenen Verträge.

Die vorhandenen Projektwerte bleiben unverändert. Externe Berichte müssen
ihre Aussage ausdrücklich auf diese Werte abbilden:

| Berichtsbegriff | Projektaussage |
|---|---|
| `PASSED` | `PASS` nur für den vollständig geforderten Scope einschließlich Oracles und erforderlichem Cleanup. |
| `FAILED` | `FAIL`; Cleanupfehler zusätzlich als `RECOVERY_REQUIRED` erhalten. |
| `INCONCLUSIVE`, `UNKNOWN` | Kein `PASS`; unbekannte Ursache oder unvollständiger Nachweis ausdrücklich nennen. |
| `BLOCKED`, `UNAVAILABLE`, `NOT_EXECUTED` | Fehlender erforderlicher Nachweis, gegebenenfalls `NOT_EXECUTED` mit Grund; keine Mergefreigabe daraus. |
| `NOT_APPLICABLE`, `NOT_REQUIRED` | Deterministisch begründete Nichtauswahl; keine ausgeführte Native-Acceptance. |
| lokales `REUSED` | Beibehaltener Development-Nachweis, keine neue Ausführung und kein CI-PASS. |
| `REUSED_VERIFIED` | Nur nach unabhängiger vertrauenswürdiger Verifikation; derzeit für Local-to-Remote nicht implementiert. |

Exitcode 0 oder ein grüner Teiltest ersetzt keine fehlenden Resultsets,
Oracles, Pflichtfälle oder Abschluss-/Cleanup-Nachweise. Kompakte Erfolge
nennen Scope, erforderliche Gates, Source-/Testbindung, tatsächliche Counts,
Status, Dauer und zulässige Evidence-Referenzen, soweit vorhanden. Keine
Beispielzahlen als Laufresultate und keine neue globale Statusenumeration.
Die Routinebewertung verlangt kein Modell als Oracle oder Erfolgsbestätiger.
Fehlerdiagnose und verpflichtende unabhängige Reviews folgen der Kostenrichtlinie.

## 3. Local-to-Remote: Vertrauensgrenze vor Optimierung

**Iststand: `NOT_IMPLEMENTED`.** Es gibt keinen unabhängigen vertrauenswürdigen
Producer/Verifier, der lokale Native-Tests für GitHub attestiert. Der vorhandene
`LOCAL_STATIC_EVIDENCE/v1`-Cache ist ausschließlich eine lokale Development-
Optimierung für Documentation/CiStrategy. Seine Hash-/Zeit-/Logbindung schützt
gegen versehentliche Wiederverwendung, nicht gegen einen Worker, der selbst
Record und Log schreiben kann. CI deaktiviert diesen Cache; Integration und
Release verwenden ihn nicht. Bestehende Ownership-/Run-Binder belegen ihre
jeweilige Ressourcenzuordnung, keine unabhängige Herkunft der Testwahrheit.

Ein späterer Reuse darf nur die native Wiederholung ersetzen. Ein unabhängig
vertrauenswürdiger Verifikator muss weiterhin einen regulären aktuellen
GitHub-Status herstellen. Die relevante Bindung umfasst mindestens:

- Repository, wirksame Source-/Build-/Dependencybytes und den erforderlichen
  PR-Head, Test-Merge-Ref oder Merge-Group-Tree;
- Test-/Oracle-/Harness-/Verifierdefinition, vollständigen ausgewählten Scope,
  Parameter, Fixtures und erwartete Ergebnisverträge;
- fachlich relevante SQL-Version/Build/Compatibility Level/Collation,
  Plattform, Provider, Image-Digest, Rechte, Runtime-, Client- und TLS-Grenzen;
- zulässige Producer-/Hostidentität und unabhängig überprüfte Provenienz,
  Integrität, Freshness sowie gegebenenfalls Widerruf;
- vollständige positive/negative Oracles, Ownership, Abschluss und Cleanup
  sowie relevante externe State-/Runtime-/Umgebungsdrift ohne Git-Änderung.

Der Testworker darf seine Autoritätsattestation nicht selbst erzeugen oder
ändern können. Der Verifikator kommt aus einem vertrauenswürdigen Kontext,
nicht aus frei geändertem PR-Code. Selbstgeschriebenes `PASS.json`, Loghash,
Commit oder eine Signatur ohne überprüfte Aussteller-/Scopeautorität genügt
nicht. Ein Modell attestiert keine Testausführung. Fachlich zugelassene
Äquivalenz muss konkret belegt sein; kein pauschaler Transfer zwischen SQL-
Versionen, Providern, Rechten oder Images.

Fehlende, manipulierte, unvollständige oder abgelaufene Evidence, neue relevante
Inputs, neue Required Gates, fehlendes Cleanup/Oracle und externe Drift
verlangen `EXECUTE_REQUIRED`: regulär ausführen, soweit autorisiert; andernfalls
sichtbar blockieren. Erst unabhängig geprüfte vollständige Gleichwertigkeit
erlaubt `REUSED_VERIFIED`. Eine begründete Nichtauswahl ist `NOT_REQUIRED`.
Diese Namen sind Entscheidungsbegriffe für eine mögliche Implementierung,
keine bereits angebotene API oder aktive CI-Reuse-Lane.

Vor einer Implementierung vorhandene Receipts, Hash-, Provenienz- und
Ownershipverträge prüfen. Keine zweite Registry oder dauerhafte Steuerung
ohne nachgewiesenen Bedarf. Schnelle statische CI-Prüfungen werden bevorzugt
erneut deterministisch ausgeführt. Kein Modellaufruf für die Reuseentscheidung.

## 4. GitHub-Gates und Datenschutz

Branchschutz, erwartete Check-Source/Appidentität, Event und aktuelle Revision
bleiben gebunden. Ein erfolgreicher manueller Dispatch oder PR-Head-Nachweis
belegt nicht automatisch den Required Check eines Test-Merge-/Merge-Group-
Stands. Bei Einsatz einer Merge Queue ihre eigene Event-/Treebindung prüfen;
keine Trigger ohne den entsprechenden Consumervertrag hinzufügen.
Keine Skip-Commitmarker, Workflow-Path-Filter oder künstlichen Statusupdates
als Gateumgehung verwenden. Der vorhandene Abschlussjob prüft ausgewählte
Provider und deren tatsächlich abgeschlossenes Capability-Inventar.

Vor Schreiben, Git oder Transfer gelten die geklärten Privacyregeln aus
[WORKING_RULES](../../.ai/WORKING_RULES.md#3-datenschutz). Synthetische Fixtures
und bereinigte fachliche Regeln dürfen im autorisierten Scope integriert
werden. Reale Host-/SQL-/Testumgebungsdaten, Secrets, Endpunkte, private Pfade
und Rohlogs bleiben lokal und unversioniert. Ein künftiger Evidence-Transport
benötigt eine eigene Daten-/Berechtigungsprüfung und höchstens eine erlaubte
minimale versionierte Kontrollreferenz. Reuse erteilt keine Uploadfreigabe.
Laufende native Jobs nicht zur Beschleunigung unkontrolliert abbrechen.

Primärreferenzen: [Required Checks](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks),
[Workflow-Skips](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs)
und [Artifact Attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations).
Build-Provenienz allein beweist keine korrekte beliebige lokale Testausführung.

## 5. Regression und gemessener Aufwand

Die vorhandene CiStrategy-/ValidationScope-Regression prüft getrennte
Provider, gemeinsame/ähnliche/unbekannte und gemischte Pfade, Capability-
Voraussetzungen, Admission vor Providerpreflight und manipulierte/fehlende/
abgelaufene lokale Records. Die Parentfixture prüft auch echten CI-Modus:
ein workererzeugtes PASS kann einen fehlgeschlagenen Child nicht grün machen;
ein gültiger warmer Development-Record verhindert die frische CI-Ausführung
nicht. Das sind lokale synthetische Prozesse, keine Remote-Attestation.

Bei einer späteren Reuseimplementierung sind zusätzlich der positive
vertrauenswürdige Remote-Verifikationspfad samt aktuellem Required Check,
Producer-/Verifiermanipulation, Test-/Oracle-/Source-/Fixtureänderung,
Versions-/Provider-/Rechteabweichung, State-/Freshnessdrift, falscher
PR-/Merge-Tree, unvollständige Oracles und Cleanup sowie gemischte invalidierte
Gates zu testen. Solange der Mechanismus fehlt, bleibt diese Native-/Remote-
Abnahme `NOT_EXECUTED`; die bestehenden CI-Gates bleiben erforderlich.

Queuezeit, Setup/Bootstrap, Host-Mutexwartezeit, SQL-Readiness, Lifecycle,
Capabilitytests und Cleanup getrennt messen, soweit bestehende Schnittstellen
verlässliche Werte liefern. Jobdauer ist kein isolierter Providertest und
keine Mutexmessung. Modell-/Reviewkosten separat ausweisen. Keine teure neue
Telemetry nur für die Messung; ungemessene Einsparungen bleiben `UNKNOWN`.

### Audit und Verarbeitungsbewertung vom 2026-10-19

Ausgangsstand ist `7b098bc3d170e4fbc73a06cb4a773260de1c7c09`.
Die tatsächlichen Selektoren, PR-/Nightly-/Runtime-Verträge und der lokale
Cache wurden gegen diese Regeln geprüft:

- Bereits implementiert: additive Provider-/Capability-Auswahl, Offline-
  Ausnahmen mit Negativfällen, fünf Provider beim unbekannten Produktpfad,
  frische CI, lokale vierstündige Development-Bindung und kompakte lokale Logs.
- Konservative Ausnahme: `Private/ConsoleHelp.ps1` und
  `Public/Clear-SqlServerLab.ps1` wählen derzeit alle fünf Provider. PR #805
  berührte diese ausführbaren Dateien neben UI/Dokumentation. Die Pfadauswahl
  kann dort Text und Seiteneffekte nicht unterscheiden. Eine kleinere sichere
  Alternative ist ohne geprüfte semantische Trennung nicht implementiert.
  Die bestehenden Confirmation-/Abbruch-/Ownership-/Cleanupfälle bleiben nötig.
- Keine neue Matrix, keine Änderung an Nightlyfrequenz, Nativeharness,
  Required Checks oder Laufzeitgate. Neue Regression nur im bestehenden
  CiStrategy-Einstieg; keine zusätzliche Validator-, Registry- oder Logpipeline.
  Die aktualisierte Selektorhilfe korrigiert lediglich die veraltete Aussage
  eines Docker-only-Fallbacks. Die ausführbare Auswahl bleibt unverändert.
- Ein Implementierungsowner, Review nur für den stabilen Scope und konkrete
  offene Findings; keine Review-von-Review- oder modellbasierte Erfolgsroute.
  Rohlogs bleiben lokal. Anstehende unveränderte Jobs erhalten keine Replays.
- Local-to-Remote bleibt mangels unabhängiger Vertrauensgrenze nicht
  implementiert. Wiederaufnahme erst mit konkret ausgewähltem und geprüftem
  Producer-/Verifier-/Daten-/GitHub-Statusvertrag; bis dahin keine Gateausnahme.
- Die historischen Jobdauern sind keine fairen Providerbenchmarks. Der Audit
  bestätigt keine Mittelwerte über eine neue Laufstichprobe und keine gemessene
  Vorher-/Nachher-Ersparnis. Zeit-, Geld- und Tokenersparnis: `UNKNOWN`.
