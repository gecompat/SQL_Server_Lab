# Anbieterneutrale Richtlinie zur kosten- und qualitätsoptimierten Verarbeitung

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-08-21 |
| Geltungsbereich | KI-unterstützte Entwicklung, Diagnose, Review, Planung, Tests und Betrieb |

Diese Richtlinie gilt unabhängig vom verwendeten KI-Anbieter, Modell,
Agenten-Framework oder Ausführungsort. Sie ist insbesondere anwendbar auf:

- ChatGPT, Codex und OpenAI-Modelle;
- Claude und andere Anthropic-Systeme;
- Gemini und andere Google-Systeme;
- GitHub Copilot und vergleichbare Coding-Agenten;
- lokal ausgeführte Open-Source-Modelle;
- selbst gehostete oder unternehmensinterne KI-Systeme;
- Systeme, die keinen automatischen Modellwechsel unterstützen.

Anbieterspezifische Begriffe wie `Reasoning Effort`, `Thinking Budget`,
`Model Tier`, `Agent Mode` oder `Pro Mode` sind als funktional vergleichbare
Steuerungsmöglichkeiten zu verstehen. Es werden nur Funktionen genutzt, die im
tatsächlich eingesetzten System verfügbar sind.

## Ziel

Jede Aufgabe wird mit möglichst geringen Gesamtkosten bearbeitet, ohne die
erforderliche Qualität, Sicherheit, Zuverlässigkeit oder Nachprüfbarkeit zu
unterschreiten.

Gesamtkosten umfassen insbesondere:

- Modell-, Token- und API-Kosten;
- lokale Rechenzeit, GPU-, CPU-, Energie- und Infrastrukturkosten;
- Reasoning- oder Thinking-Aufwand;
- Werkzeug-, Such- und externe API-Aufrufe;
- Kontextgröße und wiederholte Kontextübertragungen;
- fehlgeschlagene Versuche und Nacharbeiten;
- Test-, Build- und Validierungsaufwand;
- menschlichen Prüf- und Korrekturaufwand;
- Laufzeit und unnötige Parallelverarbeitung.

Die optimale Verarbeitung ist nicht zwingend die billigste einzelne Anfrage.
Entscheidend sind die Gesamtkosten bis zu einem verlässlich geprüften Ergebnis.

## Verfügbare Möglichkeiten feststellen

Vor umfangreichen Arbeiten wird, soweit dies ohne nennenswerten Aufwand möglich
ist, ermittelt:

- welches KI-System und welche Modelle tatsächlich verfügbar sind;
- ob ein Modellwechsel technisch unterstützt wird;
- welche Kontext-, Werkzeug- und Reasoning-Funktionen vorhanden sind;
- ob separate Kontingente oder Flatrates bestehen;
- ob lokale Modelle oder lokale Werkzeuge verfügbar sind;
- welche Test-, Build- und Entwicklungsumgebung das Projekt bereits
  bereitstellt.

Preise, Fähigkeiten, Kontingente oder Modellwechsel werden nicht erfunden. Wenn
keine zuverlässigen Kosteninformationen verfügbar sind, gelten relative
Kategorien:

- günstig und schnell;
- ausgewogen;
- leistungsfähig und teuer.

Ein lokales Modell ist nicht automatisch die günstigste Wahl. Laufzeit,
Hardwareverbrauch, Ergebnisqualität und mögliche Nacharbeit werden ebenfalls
berücksichtigt.

## Aufgaben zerlegen

Ein Modell wird nicht pauschal für die gesamte Aufgabe gewählt. Umfangreiche
Aufgaben werden in sinnvolle, überprüfbare Teilschritte zerlegt. Für jeden
Schritt wird das kostengünstigste verfügbare System gewählt, das diesen Schritt
voraussichtlich zuverlässig erledigen kann.

Eine Zerlegung wird vermieden, wenn Koordination, Kontextübergabe oder
zusätzliche Modellaufrufe mehr kosten als sie einsparen.

## Auswahl des KI-Systems

Günstige Modelle oder lokale Systeme werden für klar definierte, risikoarme und
leicht überprüfbare Arbeiten bevorzugt, beispielsweise:

- Suche und Bestandsaufnahme;
- Klassifikation und Strukturierung;
- Zusammenfassungen und einfache Textbearbeitung;
- standardisierte oder mechanische Codeänderungen;
- Formatierung und Datentransformation;
- Ausführung eindeutig beschriebener Schritte;
- Ausführung vorhandener Tests;
- Auswertung eindeutiger Testergebnisse;
- Erzeugung einfacher Testdaten.

Falls ein separates Kontingent vorhanden ist, beispielsweise für Codex Spark
oder ein anderes System, wird dieses für geeignete Routinearbeiten bevorzugt,
solange die erforderliche Qualität erreicht wird.

Ein leistungsfähigeres Modell wird insbesondere verwendet für:

- Architektur- und Entwurfsentscheidungen;
- schwierige oder mehrdeutige Fehlersuche;
- widersprüchliche Anforderungen;
- sicherheitskritische Änderungen;
- mögliche Datenverluste oder irreversible Aktionen;
- anspruchsvolle Code- und Sicherheitsreviews;
- große oder stark vernetzte Kontextmengen;
- Entscheidungen mit erheblichen Folgekosten;
- Fehler, die nur schwer durch Tests erkannt werden können.

## Reasoning- und Thinking-Aufwand

Wenn das System einen Reasoning-, Thinking- oder Berechnungsaufwand unterstützt,
wird mit der niedrigsten plausibel ausreichenden Stufe begonnen.

Der Aufwand wird nur erhöht, wenn:

- relevante Unsicherheiten bestehen bleiben;
- Tests oder andere Akzeptanzkriterien fehlschlagen;
- komplexe Anforderungen gegeneinander abgewogen werden müssen;
- ein Fehler erhebliche Auswirkungen hätte;
- oder die niedrigere Stufe nachweislich nicht ausreicht.

Der höchste Aufwand wird nur für besonders schwierige, qualitätskritische
Schritte genutzt. Danach wird zu einer günstigeren Konfiguration zurückgekehrt.

## Eskalation und Rückkehr

Zu einem leistungsfähigeren Modell oder System wird gewechselt, wenn mindestens
eines der folgenden Kriterien erfüllt ist:

1. Das aktuelle System liefert wiederholt unvollständige oder falsche
   Ergebnisse.
2. Tests oder andere Validierungen schlagen fehl.
3. Wichtige Unsicherheiten bleiben bestehen.
4. Die Aufgabe ist komplexer oder riskanter als angenommen.
5. Die Kosten eines möglichen Fehlers übersteigen die erwartete Einsparung.
6. Kontextmenge oder fachliche Tiefe überschreiten die Fähigkeiten des
   aktuellen Systems.

Der gleiche fehlgeschlagene Ansatz wird nicht beliebig wiederholt. Zunächst
wird die Fehlerursache kurz analysiert und anschließend zwischen einer
gezielten Korrektur und einer Eskalation entschieden.

Nach dem schwierigen Teilschritt wird wieder zu einem günstigeren System
zurückgekehrt, sofern die verbleibenden Arbeiten dies erlauben.

## Kontextübergabe

Bei einem Modell- oder Systemwechsel werden alle bestätigten Ergebnisse
übernommen. Übergeben werden nur:

- Ziel und aktueller Arbeitsstand;
- relevante Anforderungen und Einschränkungen;
- bestätigte Fakten und Entscheidungen;
- geänderte Dateien oder Komponenten;
- ausgeführte Tests und deren Ergebnisse;
- aufgetretene Fehler;
- offene Fragen;
- Akzeptanz- und Abschlusskriterien.

Abgeschlossene Analysen werden nicht wiederholt, sofern neue Erkenntnisse dies
nicht erforderlich machen.

## Lokale Tests und Validierung

Lokale, nicht destruktive Tests werden bevorzugt, wenn eine lokale Projekt- oder
Testumgebung verfügbar ist.

Zunächst werden geprüft:

- vorhandene Projekt- und Agentenanweisungen;
- Testkonfigurationen und dokumentierte Testbefehle;
- vorhandene virtuelle Umgebungen, Container oder Toolchains;
- betroffene Module, Pakete und Abhängigkeiten;
- bereits vorhandene Tests für das geänderte Verhalten.

Es gilt folgende kostenoptimierte Validierungsreihenfolge:

1. Zuerst werden die kleinsten relevanten Tests für das geänderte Verhalten
   ausgeführt.
2. Anschließend werden notwendige Typ-, Syntax- oder Lint-Prüfungen ausgeführt.
3. Betroffene Integrationen oder Builds werden getestet, wenn die Änderung sie
   berührt.
4. Eine vollständige Testsuite wird nur ausgeführt, wenn Risiko, Änderung oder
   Projektregeln dies rechtfertigen.
5. Unveränderte erfolgreiche Tests werden nicht ohne konkreten Grund
   wiederholt.

Für lokale Tests werden bevorzugt:

- vorhandene Projektwerkzeuge;
- lokale Testdaten;
- synthetische Daten und Fixtures;
- Mocks oder Stubs für kostenpflichtige externe Dienste;
- lokale Datenbanken oder Testcontainer;
- fokussierte Tests statt unnötiger vollständiger Testläufe.

Während Tests werden nach Möglichkeit vermieden:

- kostenpflichtige Produktions-APIs;
- Änderungen an Produktivdaten;
- echte Käufe, Nachrichten oder externe Schreibzugriffe;
- unnötige Netzwerkzugriffe;
- die Ausgabe oder Speicherung von Secrets;
- globale oder systemweite Installationen;
- Änderungen außerhalb des autorisierten Projektbereichs.

Fehlende Abhängigkeiten werden nur installiert und zusätzliche Dienste nur
gestartet, wenn dies im Projekt vorgesehen, sicher und verhältnismäßig ist. Vor
erheblichen Kosten, externen Änderungen oder systemweiten Auswirkungen ist eine
Bestätigung erforderlich.

Tests werden niemals als erfolgreich bezeichnet, wenn sie nicht tatsächlich
ausgeführt wurden. Sind lokale Tests nicht möglich, werden dokumentiert:

- der Grund, warum sie nicht ausgeführt werden konnten;
- die stattdessen durchgeführte Prüfung;
- das verbleibende Restrisiko;
- der konkrete als Nächstes auszuführende Test.

## Werkzeuge und externe Dienste

- Nur für den aktuellen Schritt relevante Werkzeuge werden genutzt.
- Lokale und bereits vorhandene Werkzeuge werden vor zusätzlichen
  kostenpflichtigen Diensten bevorzugt.
- Unveränderte Inhalte werden nicht wiederholt eingelesen.
- Große Zwischenergebnisse werden vor der Weitergabe zusammengefasst.
- Gleichartige Operationen werden gebündelt, wenn dies sicher und günstiger
  ist.
- Nur unabhängige Arbeiten mit erkennbarem Nutzen werden parallelisiert.
- Für Such-, Retry- und Werkzeugschleifen werden Abbruchbedingungen definiert.
- Erforderliche Sicherheits- oder Validierungsprüfungen werden nicht
  eingespart.
- Externe, kostenpflichtige oder irreversible Aktionen werden nicht ohne die
  erforderliche Zustimmung ausgeführt.

## Systeme ohne Modellwechsel

Wenn das verwendete KI-System keinen Modellwechsel unterstützt:

- wird mit dem verfügbaren System weitergearbeitet;
- werden Kontextmenge, Werkzeugaufrufe und Antwortlänge optimiert;
- wird die Aufgabe in kleine, überprüfbare Schritte zerlegt;
- werden lokale Tests als Rückkopplung genutzt;
- werden unnötige Wiederholungen vermieden;
- wird durch zusätzliche Prüfung oder menschliche Entscheidung eskaliert, wenn
  kein stärkeres Modell verfügbar ist;
- wird kein Modellwechsel behauptet, der tatsächlich nicht stattgefunden hat.

Kann ein System keine lokalen Werkzeuge oder Tests ausführen, bereitet es
konkrete Testbefehle vor und kennzeichnet deutlich, dass diese noch ausgeführt
werden müssen.

## Kommunikation

Die interne Modell- oder Systemwahl wird nicht bei jedem Schritt berichtet. Sie
wird nur erwähnt, wenn:

- ein teureres System aus einem konkreten Grund erforderlich ist;
- eine technische Einschränkung Qualität oder Validierung beeinflusst;
- lokale Tests nicht möglich waren;
- eine relevante Kostenabwägung erforderlich ist;
- oder ausdrücklich nach der Verarbeitungsstrategie gefragt wurde.

Die Abschlussmeldung gibt knapp an:

- welches Ergebnis erreicht wurde;
- welche relevanten lokalen Tests tatsächlich ausgeführt wurden;
- ob diese erfolgreich waren;
- welche Prüfungen nicht möglich waren;
- welche wesentlichen Risiken oder offenen Punkte verbleiben.

## Erfolgsmaßstab

Eine Verarbeitung gilt als kostenoptimal, wenn sie mit der günstigsten
verfügbaren Kombination aus KI-System, Reasoning-Aufwand, Werkzeugen und lokalen
Tests alle erforderlichen Qualitäts-, Sicherheits-, Zuverlässigkeits- und
Validierungskriterien erfüllt.
