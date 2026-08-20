# Modell- und Agenten-Routing

| Merkmal | Wert |
|---|---|
| Status | `BINDING` |
| Stand | 2026-08-20 |
| Geltungsbereich | KI-unterstützte Entwicklung, Diagnose, Review, Planung und Betrieb |

## 1. Grundsatz

Vor jeder Aufgabe werden die tatsächlich verfügbaren KI-Modelle bewertet.
Ausgewählt wird das kostengünstigste und kontexteffizienteste Modell, das für
die konkrete Aufgaben- und Risikoklasse die notwendige Qualität zuverlässig
liefert. Ein leistungsstärkeres Modell wird nicht allein deshalb verwendet,
weil es verfügbar ist.

Qualität und Sicherheit haben Vorrang vor Kosten. Die Kostenregel darf keine
notwendige Architektur-, Security-, Privacy-, Autorisierungs-,
Nebenläufigkeits-, Cleanup- oder Datenverlustprüfung abschwächen.

Modellnamen, Verfügbarkeit, Kontingente und Preise sind Eigenschaften der
jeweiligen Laufzeit und kein dauerhafter Produktvertrag. Deshalb erfolgt die
Bewertung bei jeder neuen Aufgabe anhand der aktuellen Auswahl.

## 2. Besondere Runtime-Annahme für Codex Spark

Für die vom Repository-Eigentümer verwendete ChatGPT-/Codex-Umgebung gilt als
benutzerbestätigte Runtime-Annahme:

- die technische Modell-ID lautet `gpt-5.3-codex-spark`;
- Codex Spark besitzt ein eigenes Tokenkontingent;
- das Modell kann verfügbar und explizit auswählbar sein, obwohl es in einer
  angezeigten Liste verwendbarer Modelle fehlt;
- das Fehlen in einer UI- oder Tool-Liste reicht deshalb nicht aus, um Codex
  Spark als nicht verfügbar einzustufen.

Wenn der Ausführungsweg eine explizite Modell-ID akzeptiert, wird
`gpt-5.3-codex-spark` für vollständig spezifizierte, atomare Coding-Pakete,
fokussierte Tests und klar begrenzte mechanische Änderungen bevorzugt geprüft.
Es wird nicht für offene Architektur-, Security-, Privacy-, Nebenläufigkeits-
oder Datenverlustentscheidungen verwendet.

Diese Kontingentannahme ist keine allgemeine öffentliche OpenAI-Produktzusage.
Sie wird bei geänderten Runtimebedingungen erneut geprüft, aber nicht allein
aufgrund einer unvollständigen sichtbaren Modellliste verworfen.

## 3. Entscheidungsfolge

Vor Ausführung bestimmt der koordinierende Task:

1. konkrete Aufgabe, erlaubten Scope und Abnahmekriterien;
2. Risiko für öffentliche Verträge, State, Secrets, Providerressourcen,
   Cleanup, Nebenläufigkeit und Datenverlust;
3. ob eine Entscheidung offen oder die Umsetzung bereits vollständig
   spezifiziert ist;
4. ob lokale Werkzeuge die Arbeit deterministisch ohne Modell erledigen können;
5. welche Modellklasse die verbleibende Arbeit mit ausreichender Qualität
   ausführen kann;
6. ob ein unabhängiger, begrenzter Teilauftrag eine Delegation rechtfertigt.

Bei gleicher erwarteter Qualität gewinnt in dieser Reihenfolge:

1. deterministische lokale Auswertung ohne zusätzliches Modell;
2. kleineres beziehungsweise kostengünstigeres Modell;
3. niedrigere ausreichende Thinking-Stufe;
4. weniger Kontext und weniger Agentenübergaben.

## 4. Aufgabenklassen

| Aufgabenklasse | Erforderliche Modellklasse | Typische Beispiele |
|---|---|---|
| lokale mechanische Auswertung | kein Modell oder kleinste verfügbare Klasse | Test-Counts, Log-Deduplizierung, Dateisuche, Format- und Linkprüfung |
| read-only Status und begrenzte Recherche | kleine schnelle Klasse | Branch-/CI-Status, Repo-Inventar, Diff-Zusammenfassung |
| atomare Umsetzung mit festem Vertrag | kleine Coding-Klasse | klar spezifizierte PowerShell-Funktion, Testergänzung, Mapper, Dokumentationspflege |
| Integration oder komplexe Diagnose | ausgewogene mittlere Klasse | mehrere Module, reproduzierbarer Bugfix, Provider- und State-Zusammenspiel |
| kritischer Vertrag | stärkste geeignete Klasse | öffentliche API, neue Architektur, Security, Privacy, Secret Handling, Cleanup-Vertrag |
| adversarial, nebenläufigkeits- oder datenverlustkritisch | stärkste geeignete Klasse mit erhöhter Reasoning-Stufe | Locks, Port-Races, Pfadgrenzen, Fremdobjektschutz, irreversible Mutation |

Konkrete Modell-IDs werden aus der aktuellen Laufzeit übernommen. Ist ein
Modell speziell für günstige atomare Coding-Pakete vorgesehen oder besitzt es
ein getrenntes Kontingent, wird es für passende vollständig begrenzte Pakete
bevorzugt.

## 5. Thinking-Stufe

- `low`: Status, Inventar, Suche und mechanische Prüfung;
- `medium`: normale Analyse, begrenzte Integration und klarer Bugfix;
- `high`: öffentliche Verträge, mehrere Schichten und relevante Negativfälle;
- höhere Stufen: nur für konkrete Security-, Nebenläufigkeits-, adversariale
  oder realistische Datenverlustfragen.

Eine höhere Thinking-Stufe erweitert niemals Scope oder Berechtigung. Sobald
eine kritische Frage entschieden und der Folgeauftrag mechanisch begrenzt ist,
wird auf eine günstigere Modellklasse und ausreichende niedrigere Stufe
zurückgeschaltet.

## 6. Agenteneinsatz

- Einfache sequenzielle Aufgaben werden direkt erledigt.
- Genau ein Implementierungsagent arbeitet an einem atomaren Paket.
- Parallelität ist nur bei disjunkten Dateibereichen oder unabhängigen
  read-only Analysen zulässig.
- Derselbe bewegliche Diff wird nicht parallel implementiert und semantisch
  reviewed.
- Ein Teilauftrag enthält Ausgangscommit, erlaubte Dateien, relevanten Vertrag,
  Abnahmetests und Stopbedingungen statt einer langen Chat-Historie.
- Ein stärkeres zweites Modell wird nur für eine tatsächlich unabhängige
  kritische Prüfung eingesetzt.

## 7. Kontext- und Testkosten

Vor einer Modellübergabe werden vollständige Logs, Diffs, Timings und
wiederholte Fehler lokal ausgewertet. Weitergegeben werden nur deduplizierte
Findings und kleinste relevante Ausschnitte. Es gilt insbesondere:

- kein starkes Modell zum Zählen, Filtern oder Gruppieren lokaler Ergebnisse;
- kein zusätzlicher Agent nur zum Beobachten eines unveränderten Tests;
- kein semantischer Review, solange sich der Implementierungsdiff noch ändert;
- kein vollständiger Gate nach jedem Zwischenfix;
- keine vollständigen grünen Logs oder identischen Traces im Modellkontext;
- keine wiederholte Repository-Volllektüre, wenn ein begrenzter Dateiscope und
  die autoritativen Quellen bereits feststehen.

Die verbindliche Test- und Logstrategie steht in
`Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md`.

## 8. Fallback und Eskalation

Ein Kapazitätsfehler führt nicht zu unbegrenzten Wiederholungen. Ein Fallback
ist nur zulässig, wenn die Ersatzklasse die Risikoklasse weiterhin abdeckt.
Kritische Security-, Privacy-, Autorisierungs-, Nebenläufigkeits- oder
Datenverlustentscheidungen werden nicht an eine unzureichende Modellklasse
abgegeben.

Eine Eskalation dokumentiert knapp:

- die konkrete offene Risikofrage;
- warum die bisherige Modellklasse nicht ausreicht;
- den begrenzten Kontext und die Stopbedingung;
- wann die Arbeit wieder auf eine günstigere Klasse zurückfällt.
