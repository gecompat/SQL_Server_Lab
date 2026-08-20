# Kosten- und kontexteffiziente Entwicklung

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-08-20 |
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
.\Tests\Static\Invoke-ImpactedChecks.ps1 -ChangedPath $paths
```

Reine Dokumentationsänderungen starten keine Runtime. Unbekannte produktive
Änderungen verwenden die sichere Auswahl aus `Tools/Get-CiTestSelection.ps1`.
Docker, Podman, Mixed und Hyper-V bleiben getrennte Nachweise.

Die vollständige statische Regression und die vollständige Runtime-Matrix
werden nicht nach jedem Zwischenfix ausgeführt. Sie bleiben für Nightly,
Release, ausdrückliche Abnahme oder einen Scope vorbehalten, dessen geteilter
Vertrag die vollständige Breite erfordert. Pro konsistentem stabilen Stand wird
ein erforderlicher vollständiger Gate nur einmal ausgeführt.

## 4. Wiederholungen und Diagnose

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

Ein Delegationskontext enthält nur:

- Ausgangscommit und erlaubte Dateien;
- akzeptierten Vertrag und relevante Abhängigkeiten;
- konkrete Tests und Stopbedingungen;
- lokal aggregierte, deduplizierte Findings.

Lange Chat-Historien, vollständige grüne Logs und unverbundene
Repositorytexte werden nicht weitergereicht. Modellwahl und Eskalation folgen
`.ai/MODEL_ROUTING_POLICY.md`.

## 7. Abschlussbericht

Der Abschluss einer Welle nennt knapp:

- geänderten Scope;
- verwendete Modellklasse und eine relevante Eskalation;
- lokal ausgeführte fokussierte und betroffene Prüfungen;
- Ergebnis des erforderlichen Abschluss-Gates;
- nicht ausgeführte Provider-/Native-Tests mit Grund;
- verbleibende neue Fehler oder unveränderte bekannte Fehler;
- Cleanup- oder Recoverystatus bei mutierenden Tests.
