# Kosten- und kontexteffiziente Entwicklung

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-10-05 |
| Geltungsbereich | lokale Entwicklung, KI-Arbeit, Tests, Reviews und CI-Wellen |

## 1. Ziel

SQL_Server_Lab minimiert Modellkontext, Agenten-Turns und wiederholte lokale
Rechenarbeit, ohne fachliche, sicherheitsbezogene, migrationsbezogene oder
providerspezifische Nachweise zu schwächen. Vollständige Repository-, Test- und
Laufzeitdaten werden zuerst lokal und deterministisch ausgewertet. Ein
KI-Modell erhält nur die Informationen, die für die nächste konkrete
Entscheidung oder Änderung erforderlich sind.

Kostenreduktion ist kein Grund, notwendige Tests auszulassen. Sie bestimmt die
Testreihenfolge, die lokale Ergebnisaggregation und die Breite eines
Zwischenlaufs.

Die [CI-Test- und Evidence-Regeln](CI_TEST_EVIDENCE_POLICY.md) konkretisieren
risikobasierte Auswahl, Statusbegriffe, mögliche Local-to-Remote-Nachweise und
getrennte Zeitmessungen. Sie erweitern keine Runtime- oder Uploadfreigabe.

## 2. Local-first-Auswertung

Folgende Daten werden grundsätzlich zuerst lokal ausgewertet:

- geänderte Pfade, Imports, Aufrufer und betroffene Test-Suites;
- Exitcodes, Counts, Laufzeiten und wiederholte Fehlersignaturen;
- vollständige PowerShell-, Pester-, Provider-, Git- und CI-Logs;
- Diff-, JSON-, Schema-, Katalog-, Manifest- und statische Vertragsprüfungen;
- bekannte plattform- und providerspezifische Abweichungen;
- Branch-, Commit-, Pull-Request- und CI-Status.

Wenn vollständige Logs für die Diagnose aufbewahrt werden müssen, liegen sie
unter dem ignorierten Pfad `.artifacts/test-runs/` oder in einem anderen
ausdrücklich nicht versionierten lokalen Pfad. Eine lokale Auswertung reduziert
sie auf:

- ausgeführtes Prüfprofil und relevanten Scope;
- Anzahl `PASS`, `FAIL`, `SKIP`, `NOT_EXECUTED` und Abbrüche;
- Exitcode und Gesamtlaufzeit;
- neue, deduplizierte Fehlersignaturen;
- pro neuer Signatur den kleinsten relevanten Ausschnitt;
- lokalen Artefaktpfad, falls eine spätere lokale Prüfung erforderlich ist.

Vollständige Traces, lange Listen grüner Fälle und wiederholte Instanzen
derselben Signatur werden nicht in einen Modell- oder Delegationskontext
übernommen. Reicht die Zusammenfassung nicht aus, wird nur der kleinste
zusätzliche Ausschnitt gelesen, der die offene Diagnosefrage beantwortet.

Private Artefaktpfade und Rohlogs dürfen nicht in versionierte Evidence,
öffentliche DTOs, Issues oder Pull Requests übernommen werden.

## 3. Teststufen

Eine kohärente Entwicklungswelle verwendet die folgenden Stufen in dieser
Reihenfolge:

1. **Reproduktion oder Characterization:** kleinster Test, der den Fehler oder
   bestehenden Vertrag belegt.
2. **Fokussierter Test:** unmittelbar betroffene statische Suite, Pester-Datei,
   Funktion oder Vertragsprüfung.
3. **Betroffene Regression:** Auswahl über die geänderten Pfade mit demselben
   Selektor wie im Pull-Request-Gate.
4. **Betroffener Runtime-Nachweis:** nur Docker, Podman, Mixed, Adapter oder
   Hyper-V ausführen, wenn der Änderungsscope diesen Providerpfad berührt.
5. **Abschluss-Gate:** den für den stabilen Pull-Request-, Merge- oder
   Release-Stand erforderlichen Gate genau einmal ausführen.

Die lokale betroffene Regression wird so ausgewählt:

```powershell
$paths = git diff --name-only origin/main...HEAD
.\Tests\Static\Invoke-ImpactedChecks.ps1 -ChangedPath $paths -Development
```

Reine Dokumentationsänderungen starten keine Runtime. Unbekannte produktive
Änderungen verwenden die sichere Auswahl aus `Tools/Get-CiTestSelection.ps1`.
Docker, Podman, Mixed und Hyper-V bleiben getrennte Nachweise.

### SQL-Versionen nach tatsächlicher Abhängigkeit auswählen

Generische Abläufe werden je betroffenem Implementierungs-, Provider- und
Clientkontext an einem repräsentativen gepinnten SQL-Build geprüft. Weitere
SQL-Versionen werden für denselben Ablauf nur ausgeführt, wenn ein anderer
Codezweig, eine SQL-Fähigkeit, ein versionsabhängiger Engine-/Treibervertrag
oder eine ausdrücklich noch fehlende Mindestabdeckung dies verlangt. Gleiche
Befehlsfolge und gleiche Voraussetzungen bilden eine gemeinsame Testklasse.

Versionstabellen, Buildbindungen, signierte Profilfelder und abweichende
Recordformen werden weiterhin mit kleinen Offlinefällen geprüft. Sie erzeugen
keine automatische Laufzeitmatrix. Eine offene Versionszelle der vereinbarten
Mindestmatrix benötigt ihren gezielten Nachweis, keine Wiederholung sämtlicher
UI-, Lifecycle-, Export-, Recovery- oder Consumerfälle. Die Laufzeitplanung
nennt die geprüfte Grenze, den gewählten Repräsentanten, vorhandene Belege und
den konkreten Grund für jede zusätzliche Versionsausführung. Wiederverwendung
belegt keine bisher unbeobachtete Kombination.

Die vollständige statische Regression und die vollständige Runtime-Matrix
werden nicht nach jedem Zwischenfix ausgeführt. Sie bleiben für Nightly,
Release, ausdrückliche Abnahme oder einen Scope vorbehalten, dessen geteilter
Vertrag die vollständige Breite erfordert. Pro konsistentem stabilen Stand wird
ein erforderlicher vollständiger Gate nur einmal ausgeführt.

In das GitHub-Repository werden ausschliesslich in sich konsistente, fachlich
und technisch zusammenhaengende Zustaende uebernommen. Ein solcher Stand
enthaelt die erforderlichen Code-, Vertrags-, Dokumentations- und
Testanpassungen gemeinsam und hat die fuer seinen Scope notwendigen lokalen
Gates bestanden. Unfertige Zwischenstaende werden weder als Commit oder Pull
Request veroeffentlicht noch nach `main` gemergt. Eine Ausnahme ist nur auf
ausdruecklichen Wunsch und nach expliziter Freigabe durch den User zulaessig;
der unvollstaendige Zustand und seine offenen Validierungen muessen dabei in
Commit und Pull Request klar gekennzeichnet werden.

## 4. Wiederholungen und Diagnose

Testselektion, Ausführung, Oracles, Ergebnisvergleich, Aggregation und bekannte
Fehlerklassifikation erfolgen deterministisch mit den vorhandenen Werkzeugen.
Bei vollständigem Erfolg genügt die kompakte belegte Zusammenfassung; ein
zusätzlicher Modellaufruf zur bloßen Erfolgsbestätigung entfällt. Vorgeschriebene
unabhängige fachliche oder Sicherheitsreviews bleiben erforderlich.

Fehler werden zuerst lokal nach Exitcode, tatsächlicher Fehlerstelle,
Erwartungswert, Timeout, Infrastruktur, Rechten und Cleanup klassifiziert.
Ein Modell erhält nur neue ungelöste fachliche Findings oder eine notwendige
Entscheidung mit minimalen bereinigten Ausschnitten. Ein unveränderter Blocker
begründet keine wiederkehrende Modelldiagnose.

- Ein unveränderter grüner Test wird ohne begründete Abhängigkeitswirkung nicht
  erneut ausgeführt.
- Ein bekannter Fehler wird einmal klassifiziert und im erforderlichen
  Abschluss-Gate erneut bewertet.
- Eine Wiederholung benötigt geänderten Code, geänderten Input, eine andere
  Plattform- oder Providerannahme oder eine ausdrücklich geplante
  Flake-/Stabilitätsmessung.
- Wiederholtes Polling ohne neue Evidence ist zu vermeiden.
- Nach einem Fix wird zuerst fokussiert geprüft; der breite Gate folgt erst am
  stabilen Ende der Welle.
- `SKIP` und `NOT_EXECUTED` sind keine grünen Runtime-Nachweise. Ein erreichbarer
  Providerfehler bleibt `FAIL`.

## 5. Mutierende Runtime-Tests

Provider-Smokes sind teuer und verändern lokale Ressourcen. Deshalb gilt:

- zuerst statische und nicht mutierende Verträge prüfen;
- nur den betroffenen Provider und die betroffene Fähigkeit ausführen;
- synthetische Testdaten verwenden;
- vor Arrange beziehungsweise Mutation Scope, State und Cleanup sicherstellen;
- Cleanupstatus getrennt vom ursprünglichen Fehler erhalten;
- `-KeepOnFailure` nur für eine konkrete lokale Diagnose verwenden;
- Paralleltests nur ausführen, wenn Parallelität, Portvergabe, Isolation oder
  Cleanup Teil des Änderungsscope ist;
- einen erfolgreichen Docker-Lauf nicht als Podman- oder Hyper-V-Nachweis
  darstellen.

Die konkreten Einstiegspunkte und Voraussetzungen stehen in
`Tests/README.md`, `Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md` und
`Documentation/Quality/LOCAL_READINESS_CHECKLIST.md`.

## 6. Agenten- und Kontextkoordination

Eine atomare Welle besitzt genau einen aktiven Implementierungsagenten. Ein
Review beginnt mit einem stabilen Diff und konkreten Abnahmekriterien. Mehrere
Agenten analysieren nicht gleichzeitig denselben beweglichen Diff.

Zusätzliche Reviews beantworten eine konkrete offene Frage oder eine
vorgeschriebene unabhängige Beurteilung. Geschlossene Findings, Hashvergleiche
und grüne Logs lösen keine automatische Review-von-Review-Kette aus.
Lokale Diagnose/Entwicklung, PR-Integration, vollständige Qualifikation und
Release haben getrennte Aussagegrenzen. Die sechs Foundationstufen verlangen
keine sechs einzelnen Läufe; ein Nachweis kann mehrere Aussagen belegen.

`Invoke-ImpactedChecks.ps1 -Development` kann ausschließlich ausgeführte
Documentation-/CiStrategy-Ergebnisse lokal für höchstens vier Stunden
wiederverwenden. Quelle, Gitindex, Tests/Fixtures/Konfiguration, konkrete
Child-Runtimebytes und Umgebung müssen unverändert gebunden sein; fehlende
Bindung verlangt Ausführung. FAIL/UNKNOWN/RUNNING sind kein PASS. Bei belegter
Writer-Sperre lautet das Ergebnis NOT_EXECUTED. Runtimeprüfungen und CI bleiben
frisch ausgeführt; globale Integration und Release verzichten auf Reuse.

Ein Delegationskontext enthält nur:

- Ausgangscommit und erlaubte Dateien;
- akzeptierten Vertrag und relevante Abhängigkeiten;
- konkrete Tests und Stopbedingungen;
- lokal aggregierte, deduplizierte Findings.

Lange Chat-Historien, vollständige grüne Logs und unverbundene
Repositorytexte werden nicht weitergereicht. System- und Modellwahl sowie
Eskalation folgen `.ai/MODEL_ROUTING_POLICY.md`.

### Sitzungswechsel und Checkpoints

Die Foundation-1.21-Regeln unter
`.ai/foundation/AI_WORK_ORCHESTRATION_POLICY.md` ergänzen diese Richtlinie.
Der Orchestrator ist eine Rolle über dauerhaftem Projektzustand. Ein neuer
Chat lädt die nativen Instruktionen und aktuellen kanonischen Projektquellen;
eine frühere Regelanalyse wird nur nach dem eigenen Cache-Vertrag wiederverwendet.

Ein Checkpoint entsteht ereignisgesteuert an einer tatsächlichen Arbeitsgrenze
oder aus bereits verfügbaren deterministischen Kontextmetriken. Unbekannte
Tokenwerte bleiben unbekannt. Keine kontinuierliche semantische Chatanalyse,
periodische Gesamtsummierung oder Antwortlatenz als automatischer Wechseltrigger.
Eine Übergabe verwendet kanonische Zustands- und Arbeitsreferenzen sowie
höchstens ein autorisiertes lokales Delta seit dem letzten Checkpoint. Neue
Session-, Checkpoint- und Handoff-Runtimedaten bleiben außerhalb der
Versionskontrolle; der bereits versionierte Projektcheckpoint bleibt erhalten.

Automatische Nachfolgesitzungen sind als Projektentscheidung ausgewählt.
Ein automatischer Chatwechsel ist an einer gesicherten natürlichen Arbeitsgrenze
erlaubt, wenn er die Fortsetzung einer bereits autorisierten Arbeit erleichtert.
Geeignet sind beispielsweise ein abgeschlossener, validierter Slice oder ein
klar abgegrenzter nächster Arbeitsbereich einer längeren Welle. Bei kurzen
Aufgaben oder überwiegendem Übergabeaufwand wird der bestehende Chat fortgesetzt.
Eine laufende Mutation oder ungeklärte Cleanup-/Recoveryverantwortung ist keine
geeignete Wechselgrenze.

Vor dem automatischen Wechsel müssen folgende Bedingungen erfüllt sein:

- Der aktuelle Stand, ausgeführte Prüfungen, eigene Ressourcen und offene
  Aufgaben sind über einen geprüften Checkpoint und einen
  `foundation-session-handoff/v1`-Datensatz lokal gesichert.
- Aktuelle vertrauenswürdige Client-Evidence bestätigt die tatsächlich
  verfügbare Erzeugung einer Nachfolgesitzung. Diese Erzeugung und Fortsetzung
  liegen innerhalb des Benutzerauftrags und der geltenden Clientrechte.
  Modell-, Kosten- und Datenschutzpräferenzen des Benutzers gelten weiter.
- Der Nachfolger lädt native Instruktionen und aktuelle kanonische Quellen
  und bestätigt die Übernahme des konkreten Checkpoints. Bis dahin darf er
  nur den Bootstrap prüfen und keine Implementierung beginnen.
- Der Rollenwechsel wird eindeutig dokumentiert. Genau ein Orchestrator
  verantwortet die Implementierung; nach bestätigter Übergabe implementiert
  der Vorgänger keine weiteren Scopes. Zugeordnete Heartbeats werden an den
  tatsächlichen Nachfolger gebunden, bevor sie dort neue Arbeit auslösen.

Für einen so autorisierten Wechsel ist keine erneute Einzelbestätigung nötig.
Ein unbekannter, nicht unterstützter, fehlgeschlagener oder nicht bestätigter
Erzeugungs-/Übernahmeversuch fällt auf manuelle Fortsetzung zurück. Der
Checkpoint bleibt erhalten; ein unklarer Versuch führt nicht zur blinden
Erzeugung weiterer Chats. Eine vorbereitete Übergabe ist kein Nachweis für
einen tatsächlich erzeugten Chat oder einen abgeschlossenen Rollenwechsel.

Numerische Kontext- und Deltaschwellen sowie der optionale `ai-work`-Planer
bleiben nicht ausgewählt. Deren spätere Auswahl benötigt eine getrennte
Projektentscheidung; die Erlaubnis automatischer Nachfolger aktiviert sie nicht.
Eine Übergabe, ein neuer Chat oder ein Foundation-Upgrade ersetzt keinen
ausdrücklichen Startauftrag für eine pausierte Entwicklungswelle. Deren
Startgrenze bleibt im
[Pausecheckpoint](../Project_Planning/AUTONOMOUS_DEVELOPMENT_WAVE_2026-09-10.md)
maßgeblich; ein begrenzter neuer Auftrag öffnet nur seinen eigenen Scope.

## 7. Abschlussbericht

Die SQL-2022-TLS-Erweiterung nutzt denselben nativen Acceptance-Runner mit
ausdrücklicher Versionswahl und einem eigenen Lauf je betroffenem Provider.
Sie wiederholt keine unveränderten SQL-2025-/Hyper-V-Abnahmen. Die neue
Versionsfixture bleibt Bestandteil der bestehenden TLS-Suite; der Selektor
erhält die gekoppelte Ownership-Suite und sämtliche erforderlichen CI-Gates.
Ein Reviewer prüft den stabilen Profil-/Qualifikations-/Export-/Cleanup-Diff;
Hash- und Ergebnisaggregation bleiben lokal deterministisch. Es entsteht kein
neuer Review- oder Logleseragent und keine zusätzliche dauerhafte Testpipeline.

Die öffentliche Podman-TLS-Erweiterung verwendet den bestehenden
OwnedRunWindows-Kern für ausschließlich frische eigene TLS-Roots. Der
unabhängige Review deckte die bisher nicht durchgängig gepinnte öffentliche
Stop-/Start-/Remove-Grenze auf; die Korrektur integriert die vorhandenen
Policy-/Custodypfade und erzeugt keinen weiteren allgemeinen Lifecycle.
Die bestehenden TLS-, Cleanup- und OwnedHost-Suites prüfen die gekoppelten
Verträge; fünf einzelne Selektorfälle sichern die neuen Abhängigkeiten. Es gibt
keine Runtime-Ausnahme: die konservativen Provider-/Capability-Gates bleiben
erhalten. Der vorhandene native Acceptance-Harness erhält einen expliziten
Providerparameter und prüft die öffentlichen Lifecycle-/Cleanupgrenzen mit
nur prozesslokal ungültigen Routingvariablen. Eigene Docker- und Podman-Nachweise
bleiben getrennt. Ein Implementierer und ein Reviewer genügen; zusätzliche
Reviewrunden betreffen ausschließlich konkrete Findings und deren Deltas.
Logs werden lokal begrenzt ausgewertet; tatsächliche Token-/Geldkosten bleiben
unbekannt. Ausgeführt beziehungsweise noch ausstehend wird in der
Validierungsstrategie getrennt ausgewiesen.
Zwei neue native Fehlersignaturen erforderten eng begrenzte Image- und
Provider-Wrapperkorrekturen samt erneut gebundenen Sicherheitsprüfungen.
Ein lokaler Lauf mit einer Testisolationsabweichung wurde als abgebrochen
erhalten. Die gültige betroffene Regression umfasst 20 Suites; frühere grüne
Quellenprüfungen werden nur bei gültiger Bindung wiederverwendet. Nach sieben
grünen Docker-Fällen wurde ausschließlich dessen fehlgeschlagener Cleanup am
vorhandenen Run fortgesetzt. Insgesamt entstanden zwei Docker- und ein
Podman-Acceptance-Lab; keine dritte Docker-Neuanlage und keine Wiederholung
der sieben grünen Fälle. Die konservativen Pflichtgates bleiben erhalten.

Die zusätzliche private Hyper-V-TLS-Abnahmelane verwendet die bestehende
Guard-Suite für Writer-/Ablauf- und Kryptogegenfälle. Ihre neuen exakten
Pfadzuordnungen ergänzen keine Runtime-Ausnahme; die Änderung am Selektor
behält die konservative Provider-Matrix und ihre Pflichtgates. Der native
Referenzlauf bleibt ein getrennter einmaliger Setupversuch mit 180 Minuten
Gesamtbudget. Ein Implementierer, ein unabhängiger Reviewer und deterministische
lokale Log-/Hashauswertung genügen; zusätzliche Reviewketten oder eine
periodische Modelldiagnose entstehen nicht. Tatsächliche Token- und Geldkosten
bleiben unbekannt.

Die [native Referenzabnahme vom 2026-10-20](TLS_HYPERV_NATIVE_ACCEPTANCE_2026-10-20.md)
behielt genau diesen Implementierer/Reviewer und das ursprüngliche Budget.
Neue Reviewrunden betrafen ausschließlich konkrete Findings, neue tatsächlich
beobachtete Laufzeitgrenzen und die zugehörige feste Konfigurationsbindung.
Quelländerungen lösten neue stabile betroffene Gates aus; ein während Änderungen
gestarteter Lauf wurde verworfen. Unveränderte grüne Provider-Smokes wurden
nicht wiederholt. Ein zusätzlicher kurzlebiger Leaf am vorhandenen CSR/Key
ermöglichte direkte, getrennt persistierte Vorher-/Nachher-Ablaufbelege mit
frischen Clientprozessen; es gab keinen zusätzlichen Setupdispatch oder
ursprünglichen Key-/CSR-Replay. Logs, Manifeste und rohe Diagnosen bleiben
lokal geschützt. Die konservativen ausgewählten CI-Runtimegates bleiben Pflicht.

Der [optionale SQL-Funktionsvertrag](../Architecture/SQL_OPTIONAL_FEATURES.md)
ergänzt eine fokussierte statische Suite und getrennte native Providerläufe.
Die Shellquelle wählt Docker/Podman, der Windows-Adapter Hyper-V; gemischte
Coreänderungen behalten die konservative bestehende Matrix. Die aktuelle
Manifest-/API-Änderung behält deshalb die betroffenen breiten statischen Gates.
Die Testauswahl ergänzt keine Modellaufrufe oder zusätzliche Review-/Logpipeline.
Die Feature-Recovery-Regression wird außerdem für die exakt gekoppelten
Container-/Hyper-V-Mutatoren gewählt; der SQL-Port-Setter wählt seine bestehende
Fachsuite. Dies erhält Sperr- und Intentgrenzen ohne zusätzliche Runtimefälle.
Der bestehende Port-HTTP-Test bestand isoliert mit allen 87 Assertions in
65,3 Sekunden. Nur sein Wrapperbudget steigt von 60 auf 90 Sekunden; andere
Timeouts, sämtliche Oracles und Cleanup bleiben erhalten. Dies behebt den
beobachteten Harnessabbruch ohne zusätzliche Providerstarts oder ausgelassene
Fälle. Geld- und Tokenkosten sind unbekannt; Originalausgaben bleiben lokal.

Die begrenzte Selektorentscheidung für den [privaten TLS-Registrywriter](../Architecture/AUTHENTICATED_TLS_REGISTRY_WRITER.md)
wählt native eigene Windows-Dateisystemfixtures mit ACL-/Prozessabbruch-/
Parallelitätsfällen statt unbeteiligter SQL-Providerstarts. Nur sein exakter
Produktpfad erhält diese Ausnahme; transitive Helper, ähnliche Pfade und
gemischte Änderungen sind ausführbar regressionsgeprüft. Die allgemeine
Analyzersuite bei Testdateiänderungen, statische Pflichtgates, Nightly und
unabhängiger Review bleiben erhalten. Logs bleiben lokal; zusätzliche
Modellrunden, doppelte identische Prüfungen oder Runtime-Smokes entstehen
daraus nicht. Native Windows-Dateifälle bleiben unter Linux sichtbar ungeprüft.

Die gekoppelte [Authoritybindung](../Architecture/AUTHENTICATED_TLS_AUTHORITY_BINDING.md)
ergänzt genau eine weitere Produktpfadausnahme und eine fokussierte Suite.
Native eigene Temp-CA/DPAPI/NTFS-Fixtures verwenden injizierten positiven
Trust statt Store-/SQL-Mutationen. Transitive Quellen, gemischte Auswahl,
Nightly einschließlich Writersuite und konservative ähnliche Pfade bleiben
geprüft. Der Aufwand bleibt auf diese lokale Metadatenlane begrenzt;
notwendige Sicherheitsprüfungen und unabhängiger Review werden nicht ersetzt.
Der Abschluss einer Welle nennt knapp:

- geänderten Scope;
- eine relevante System-, Modell- oder Kostenabwägung nur, wenn sie Qualität,
  Validierung oder Ausführung beeinflusst hat;
- lokal ausgeführte fokussierte und betroffene Prüfungen;
- Ergebnis des erforderlichen Abschluss-Gates;
- nicht ausgeführte Provider-/Native-Tests mit Grund;
- verbleibende neue Fehler oder unveränderte bekannte Fehler;
- Cleanup- oder Recoverystatus bei mutierenden Tests.

Die explizite TLS-Neustartwiederbindung verwendet den bestehenden privaten Lock-/ACL-/Dateiersatzkern und eine eigene fokussierte Suite für den neuen mutierenden Recordvertrag. Der Selektor führt diese Suite bei Änderungen an ihren gekoppelten Profil-, Qualifikations-, Writer- und Dateihilfen sowie dem öffentlichen Einstieg aus; die bestehenden Ownership- und fünf Runtimegates bleiben erhalten. Keine Pfadausnahme oder Gateabsenkung wird ergänzt. Echte Native-Abnahme nutzt den bestehenden Harness mit einem ausdrücklichen zusätzlichen Szenario: zunächst ein neues eigenes Lab je Provider und nach reproduziertem Offsetfehler genau ein korrigierter Podman-Nachlauf. Alle drei Labs sind entfernt; der ursprüngliche FAIL bleibt erhalten. Ein zusätzlicher ACL-Preflightfehler wurde vor Labreservierung durch unveränderte Inhalte und explizite private Dateirechte geschlossen. Die unabhängigen Reviews betreffen den mutierenden Produktvertrag und die konkret geänderten Zulassungsgrenzen; Hash-, Log- und Ergebnisaggregation bleiben deterministisch lokal. Die notwendige zusätzliche Suite deckt reale Lock-/Replace-/LostReplyrisiken ab und wird nicht durch Modellzustimmung ersetzt. Unveränderte grüne Tests und die frühere Docker-Abnahme werden nicht als neue Nachweise wiederholt. Tatsächliche Token-/Geldkosten bleiben unbekannt; alle Wellen und Reviewdeltas teilen das bestehende endliche Budget.

Die ergänzende SQL-2025-CU9-Rebind-Abnahme verwendet den unveränderten öffentlichen Harness für zwei bisher fehlende Provider-/Recordform-Kombinationen. Nur das unabhängige Testoracle und seine Gegen-/Kompatibilitätsfälle ändern sich; Produkt und Selektor bleiben erhalten. Ein Implementierer und derselbe unabhängige Reviewer schließen konkrete Oracle- und Zulassungsfindings. Zwei neue eigene Labs mit vollständigem Cleanup liefern die fehlenden Laufzeitnachweise; frühere SQL-2019- und SQL-2025-Abnahmen werden nicht als neu ausgeführt umgedeutet. Die sieben betroffenen statischen Suites, das anschließende Dokumentationsdelta und das finale PR-Gate bleiben erforderlich. Das gemeinsame endliche Wellenbudget wird nicht erneuert; tatsächliche Geld-/Tokenkosten bleiben unbekannt.

Die ergänzende SQL-2022-CU27-Rebind-Abnahme schließt ausschließlich zwei fehlende native Providerkombinationen mit unverändertem öffentlichem Harness. Ein Implementierer und derselbe unabhängige Reviewer genügen. Zwei neue eigene Labs liefern die zusammengesetzten Nachweise; vorhandene grüne TLS-Quellenprüfungen werden bei unveränderten relevanten Bindungen nicht wiederholt. Das reine Dokumentationsdelta nutzt seine betroffenen Doku-/Privacy-Suites und den unveränderten finalen PR-Gate. Der neue direkte Folgeauftrag besitzt ein gemeinsames endliches Budget von höchstens zwei PRs und sechs Acceptance-Labs innerhalb von vier Stunden; keine automatische Erneuerung, tatsächliche Geld-/Tokenkosten unbekannt.

Die explizite Verbindungstext-Kopie nutzt die vorhandene WorkflowUI-Suite
statt einer weiteren Suite oder Modellpipeline. Der Selektor erkennt den
exakten neuen Fixturepfad unter Windows und POSIX. Nur die reine
Clipboarddatei erhält eine präzise Ausnahme von der Operator-Transportannahme;
ihre fehlenden Netzwerkzugriffe bleiben ausdrücklich geprüft. Übrige Assets,
voller Analyzer und erforderliche PR-Gates behalten ihre Pflichten. Sechs
unveränderte zuvor grüne Suites und acht korrigierte Deltas liefern die
betroffene 14-Suiten-Abdeckung ohne gemeinsame Wiederholung. Vier getrennte
positive Browser-/SQL-Zellen und genau ein begründeter Podman-Nachlauf nach
beobachtetem ACK-Timeout genügen; die drei grünen Zellen werden nicht erneut
ausgeführt. Ein Implementierer und derselbe unabhängige Reviewer beurteilen
Produkt, neue Zulassungsgrenzen und tatsächliche Belegbindung. Vollständige
Originallogs und private Kopien bleiben lokal. Das gemeinsame endliche Budget
gilt auch für Korrekturen; tatsächliche Geld-/Tokenkosten bleiben unbekannt.
