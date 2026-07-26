# Verbindlicher Qualitätsvertrag für Analyse-Dokumentation

**Vertragsversion:** 3<br>
**Stand:** 22. Juli 2026<br>
**Geltungsbereich:** alle öffentlichen Procedures unter `Documentation/Analysis_Guides/Procedures/`

## Qualitätsstufen und aktueller Stand

Die Existenz einer Procedure-Seite ist noch kein Nachweis fachlicher Tiefe. Deshalb werden zwei überprüfbare Stufen getrennt:

- `BASELINE`: Die Procedure ist strukturell erfasst und besitzt die bisherigen technischen Vertiefungsfelder. Die Seite ist noch nicht vollständig gegen Vertragsversion 3 redaktionell geprüft.
- `DEEP_REVIEWED`: Zweck, Leserichtung, Datenentstehung, Aussagegrenzen, Eigenlast und Gegenproben wurden am aktuellen T-SQL geprüft; alle nachfolgenden Pflichtinhalte sind erfüllt.

Der maschinenlesbare Stand liegt in [`Metadata/Quality/Analysis_Documentation_Review.csv`](../../Metadata/Quality/Analysis_Documentation_Review.csv). Zum Stand dieses Vertrags sind **89 von 94** Seiten `DEEP_REVIEWED`; fünf PLAN-001-/SC-023-Seiten bleiben `BASELINE`. Als Kalibrierungsfälle für unterschiedliche Kosten- und Zeitmodelle dienen weiterhin:

1. [`USP_CurrentRequests`](Procedures/USP_CurrentRequests.md) als flüchtige Live-DMV-Analyse,
2. [`USP_IndexPhysicalStats`](Procedures/USP_IndexPhysicalStats.md) als potenziell I/O-intensiver physischer Scan,
3. [`USP_ExtendedEventsReadEvents`](Procedures/USP_ExtendedEventsReadEvents.md) als Datei-/XML-Analyse mit möglicher Nebenwirkung.

Eine Abdeckungszahl darf nur zusammen mit ihrer Qualitätsstufe genannt werden. Aktuell ist die strukturelle Abdeckung mit 94/94 vollständig; die redaktionelle Tiefenprüfung steht bei 89/94. Eine spätere relevante Änderung an T-SQL, Resultsets, Gates oder Kostenpfaden kann einzelne Seiten gemäß den Pflege- und Reviewregeln wieder auf `BASELINE` zurücksetzen.

## Abdeckungsvertrag

Jede im öffentlichen Procedure-Referenzhandbuch geführte Procedure besitzt:

1. einen Eintrag im Objektindex,
2. eine eigenständige Seite unter `Procedures/`,
3. einen technischen Abschnitt im Familienguide,
4. eine Signatur im Procedure-Referenzhandbuch,
5. genau einen Eintrag im Review-Manifest.

## Pflichtinhalt einer tief geprüften Seite

Eine `DEEP_REVIEWED`-Seite beantwortet aus Sicht des Anwenders und aus Sicht der Engine:

1. **Entscheidungsfrage und Einsatz:** Welche konkrete Frage beantwortet die Auswertung, in welcher Betriebssituation und mit welcher erwarteten Entscheidung?
2. **Nicht beantwortete Fragen:** Welche Ursachen oder historischen Aussagen lassen sich aus dieser Quelle gerade nicht ableiten?
3. **Sicherer Einstieg:** Welcher kleine, synthetische Aufruf ist sinnvoll; welche Berechtigung, Freigabe oder bewusste Nebenwirkung ist erforderlich?
4. **Resultsets und Leserichtung:** Welche fachlichen und technischen Resultsets entstehen je Ausgabemodus und in welcher Reihenfolge werden sie interpretiert?
5. **Zeilengranularität:** Was genau repräsentiert eine Zeile; wodurch können mehrere Zeilen zum vermeintlich gleichen Objekt entstehen?
6. **Datenentstehung und Source Select:** Welche Systemquelle wird in welcher Reihenfolge gelesen, gefiltert, aggregiert, gekürzt und ausgegeben? Ein reduziertes Grundselect zeigt, soweit fachlich möglich, die tragenden `FROM`-/`JOIN`-Beziehungen und die wenigen Prädikate, die den Scope oder die Quellkosten wesentlich bestimmen. Orchestratoren, Befehlsquellen und Schreibpfade werden ausdrücklich als solche erklärt; dafür wird kein künstliches `SELECT` erfunden.
7. **Zeit-, Scope- und Resetmodell:** Snapshot, kumulative Messung, Stichprobe oder Historie; Instanz-/Datenbank-/Objektscope; Restart-, Eviction-, Retention- und Rollovergrenzen.
8. **Interpretation:** Welche Werte gehören zusammen, was ist Beobachtung, Hypothese oder Auswirkung, und welche plausible Gegenhypothese ist zu prüfen?
9. **Beispiele und Gegenbeispiele:** Mindestens ein synthetischer Problemfall und ein ähnlich aussehender unkritischer oder nicht entscheidbarer Fall.
10. **Leere oder partielle Ausgabe:** Unterschied zwischen keiner Zeile, `NULL`, 0, fehlender Berechtigung, deaktivierter Quelle, Filterwirkung und gekürzter Ausgabe.
11. **Folgeanalyse:** Mindestens eine zweite, möglichst unabhängige Evidenzquelle; keine automatische Änderungsanweisung.
12. **Primärquellen:** Links auf passende Microsoft-Produktdokumentation bei versions-, berechtigungs-, locking- oder kostenrelevanten Aussagen.
13. **Weiterführende Vertiefung (optional):** Wählen Sie externe Fach- oder Open-Source-Quellen sorgfältig aus und verwenden Sie diese nur, wenn sie die praktische Diagnose oder eine alternative Aufbereitung konkret vertiefen.

Die gemeinsame Basis bildet das [Execution-, Zeit-, Evidenz- und Kostenmodell](Technical_Foundations.md). Vollständige Spaltentabellen dürfen im Familienguide bleiben, solange die Einzelseite die für die Entscheidung benötigten Schlüsselspalten erklärt und direkt auf die Detailtabelle verweist.

## Verbindliches Kosten- und Grenzprofil

Jede `DEEP_REVIEWED`-Seite besitzt den Abschnitt `Eigenlast und Grenzen` mit einer Tabelle, die mindestens diese Dimensionen ausweist:

| Dimension | Verbindliche Aussage |
|---|---|
| Kostenklasse | `LOW`, `MEDIUM` oder `HIGH_OPT_IN`; bei variablem Verhalten als Spannweite |
| Standardpfad | Eigenlast des dokumentierten sicheren Einstiegs |
| Teuerster Pfad | konkret benannter ungünstigster erlaubter Aufruf |
| Haupttreiber | beispielsweise Requests, Datenbanken, Pages, Pläne, XEL-Dateien oder XML-Knoten |
| Skalierung | womit Laufzeit, CPU, I/O, TempDB, Speicher oder Ergebnistransfer wachsen |
| Ressourcen | primär beanspruchte Engine- und Betriebssystemressourcen |
| Begrenzungswirkung | ob `TOP`, `@MaxZeilen` oder Filter nur Ausgabezeilen oder bereits den Quellzugriff begrenzen |
| Locking und Nebenwirkungen | mögliche Locks, Blocking, Flushes, Cache-/Dateizugriffe oder sonstige Zustandswirkungen |
| Schutzmechanismus | Gate, Opt-in, Timeout, Scopepflicht oder fehlender technischer Schutz |
| Sicherer Einsatz | kleinster sinnvoller Scope und geeigneter Betriebszeitpunkt |
| Aussagegrenze | welche Genauigkeit oder Vollständigkeit durch die Begrenzung verloren geht |

Kostenklassen sind qualitative Betriebsrisiken und keine Laufzeitgarantie. `@MaxZeilen = 100` bedeutet insbesondere nicht automatisch, dass eine Quelle nur 100 Elemente lesen musste. Filter- und Limitposition in der tatsächlichen Datenkette müssen ausdrücklich beschrieben werden.

Der dokumentierte sichere Einstieg muss mit den aktuellen Analyse-Gates ausführbar sein. Wenn bereits der gezeigte kleine Pfad eine Analyseklasse mit High-Impact-Bestätigung prüft, enthält das Beispiel `@HighImpactConfirmed = 1` und erläutert, dass die Bestätigung weder Scope, Quellarbeit noch Laufzeit begrenzt. `None`, `TBD` und `N/A` sind keine Kostenklassen; nicht anwendbare Ressourcen oder Nebenwirkungen werden stattdessen in der jeweiligen Dimension begründet.

## Fachlicher Mindestvertrag

- Ein Einzelwert wird nicht als Root Cause dargestellt.
- Beobachtung, Ursachehypothese, Auswirkung und Handlung werden sprachlich getrennt.
- Prozentwerte und Durchschnitte besitzen einen erklärten Nenner.
- Findings werden als Triage, nicht als automatische Änderung behandelt.
- Status-, Warnungs- und Childresultsets werden vor Fachdaten bewertet, sofern der gewählte Ausgabemodus sie liefert.
- Query Store, Extended Events, Plan Cache und DMVs erhalten ihre jeweiligen Retention-, Reset- und Sichtbarkeitsgrenzen.
- Repository-Default, Microsoft-Produktaussage und Frameworkheuristik werden nicht miteinander vermischt.
- `NULL`, 0, leere Menge, ausgelassener Scope und Fehlerstatus werden unterschieden.

## Pflege- und Reviewregeln

- Eine Seite darf erst nach Abgleich mit aktuellem T-SQL und Familienguide auf `DEEP_REVIEWED` gesetzt werden.
- Änderungen an Quelle, Resultsets, Gates, Defaults oder Kostenpfad setzen die fachliche Prüfung der betroffenen Seite voraus. Bis zur Prüfung wird der Manifeststatus wieder `BASELINE`.
- Neue Beispiele verwenden ausschließlich eindeutig synthetische `Example*`-Werte. Reale Login-, Host-, Firmen-, Datenbank-, Objekt-, Pfad- oder Workloadwerte gehören weder in die Dokumentation noch in Reviewartefakte.
- Tiefenprüfung ist kein Wortzahlwettbewerb. Ein kurzer Pfad darf kurz bleiben, muss Nichtanwendbares aber ausdrücklich und begründet ausweisen.

## Externe Vertiefungen

Microsoft-Produktdokumentation bleibt die Primärquelle für Engineverhalten, Versionen, Berechtigungen, Locks und dokumentierte Nebenwirkungen. Externe Links stehen in einem getrennten Abschnitt `Weiterführende Vertiefung` und dürfen diese Primärquelle nicht ersetzen.

Eine externe Quelle wird nur aufgenommen, wenn sie einen konkreten Mehrwert für die betreffende Procedure besitzt, über HTTPS erreichbar ist und Autor beziehungsweise Organisation klar erkennbar sind. Bevorzugt werden etablierte, gepflegte Projektseiten oder fachlich fokussierte Referenzen. Reine Marketing-, Affiliate-, ungekennzeichnete Kopie- oder allgemeine Linklisten werden nicht verwendet. Tooldokumentation wird als alternative Praxisperspektive, nicht als Beweis für Produktaussagen beschrieben. Ein externer Link ist nicht pro Seite verpflichtend; fachliche Passung geht vor Anzahl.

## Automatische und manuelle Prüfung

Die Strukturprüfung `Code/Tests/Static/900_Validate_Analysis_Documentation.ps1` vergleicht Referenz, SQL-Signaturen, Seiten, Resultset-Inventar und Review-Manifest. Für `DEEP_REVIEWED` erzwingt sie die Vertragsüberschriften, alle Kostendimensionen, Primärquellen, Beispielkennzeichnung und eine substanzielle Mindesttiefe. Falls ein Abschnitt `Weiterführende Vertiefung` existiert, prüft sie außerdem die Trennung von Microsoft-Primärquellen und externen HTTPS-Quellen. Die externe Linkprüfung kontrolliert URL-Struktur und dauerhafte HTTP-Fehler.

Die Stilprüfung `Code/Tests/Static/915_Validate_Documentation_Style.py` blockiert bekannte Rückfälle in generische Procedure-Standardabsätze, fragmentarische Leserichtungen sowie nominale Zweck- und Hilfeformulierungen. Sie setzt die öffentliche Schreibstilrichtlinie für objektiv erkennbare Muster um, kann aber keine grammatikalische oder fachliche Gesamtbewertung automatisieren.

Diese Gates erkennen fehlende oder widersprüchliche Struktur, beweisen aber weder fachliche Richtigkeit noch angemessene Kosten im konkreten Produktionssystem. Vor jedem Merge bleiben ein manueller T-SQL-Abgleich, fachlicher Review und Datenschutzcheck des vollständigen Diffs verpflichtend.
