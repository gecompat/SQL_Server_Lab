# Template für eine Procedure-Seite

Jede neue öffentliche Analyse-Procedure benötigt eine Datei unter `Procedures/USP_Name.md` und einen Eintrag im [Review-Manifest](../../../Metadata/Quality/Analysis_Documentation_Review.csv). Der verbindliche Inhalt steht im [Qualitätsvertrag](../Documentation_Quality_Contract.md).

## Pflichtstruktur für `DEEP_REVIEWED`

```markdown
# [monitor].[USP_Name]

**Bereich:** ...
**Zweck:** ...
**Beobachtungsart:** Snapshot | kumulativ | Stichprobe | Historie | Katalog
**Kostenklasse:** LOW | MEDIUM | HIGH_OPT_IN | Spannweite

## Entscheidungsfrage und Einsatz

## Nicht beantwortete Fragen

## Sicherer Einstieg

## Resultsets und Leserichtung

## Eine Zeile bedeutet

## So lesen

## Warum kann das problematisch sein?

## Wann ist es kein Problem?

## Beispiele und Gegenbeispiele

## Leere oder partielle Ausgabe

## Eigenlast und Grenzen

| Dimension | Aussage für diese Procedure |
|---|---|
| Kostenklasse | ... |
| Standardpfad | ... |
| Teuerster Pfad | ... |
| Haupttreiber | ... |
| Skalierung | ... |
| Ressourcen | ... |
| Begrenzungswirkung | ... |
| Locking und Nebenwirkungen | ... |
| Schutzmechanismus | ... |
| Sicherer Einsatz | ... |
| Aussagegrenze | ... |

## Technische Vertiefung

[Gemeinsames Execution-, Zeit- und Evidenzmodell](../Technical_Foundations.md)

### Leitfrage

### Technischer Hintergrund

### Datenkette

### Source Select

Ein reduziertes, aus der Implementierung abgeleitetes Grundselect mit den
tragenden `FROM`-/`JOIN`-Beziehungen. Nur Prädikate aufnehmen, die den Scope
fachlich bestimmen oder teure Quellarbeit früh begrenzen. Falls kein einzelnes
Grundselect existiert, den Orchestrierungs-, Befehls- oder Schreibpfad
ausdrücklich als solchen erklären und keine künstliche Abfrage erfinden.

### Zeit- und Scope-Modell

### Bewertung und Gegenprobe

### Typische Fehlinterpretation

### Folgeanalyse

## Primärquellen

- [Passende Microsoft-Produktdokumentation](https://learn.microsoft.com/...)

## Weiterführende Vertiefung

Optional und nur bei konkretem Mehrwert:

- [Externe Fach- oder Projektquelle](https://example.org/...)

Technische Detailbeschreibung: ../Familienguide.md#anker
```

## Inhaltliche Regeln

- Beschreiben Sie den erwarteten Anwendungsfall so konkret, dass ein Leser entscheiden kann, ob die Procedure für die Fragestellung geeignet ist.
- Trennen Sie Beobachtung, Ursachehypothese, Auswirkung und Handlung.
- Erklären Sie Prozentwerte und Durchschnitte immer mit ihrem Nenner.
- Unterscheiden Sie Live-, Sample-, kumulative und historische Werte und nennen Sie Restart, Reset, Eviction, Capture und Retention.
- Unterscheiden Sie `NULL`, 0, keine Zeile, fehlende Berechtigung und partielle Quelle.
- Kennzeichnen Sie Repository-Default, Produktaussage und Heuristik.
- Erklären Sie CONSOLE als fachlichen Einstieg, RAW für vollständige technische Resultsets und TABLE für die typisierte SQL-interne Weiterverarbeitung des im Resultset-Inventar benannten Ergebnisses.
- Geben Sie bei `@MaxZeilen`, `TOP` und Filtern anhand des T-SQL an, ob sie Quellarbeit oder nur Rückgabemenge begrenzen.
- Bewerten Sie die Kosten des Standardpfads und des teuersten zulässigen Pfads getrennt.
- Der sichere Beispielaufruf muss mit den dokumentierten Gates tatsächlich ausführbar sein. Prüft bereits dieser Pfad eine Analyseklasse mit High-Impact-Bestätigung, muss er `@HighImpactConfirmed = 1` zeigen und zugleich erklären, dass die Bestätigung keine Scopebegrenzung ist.
- Leiten Sie die Kostenklasse in Kopf und Kostentabelle aus dem realen Quellpfad ab; Platzhalter wie `None`, `TBD` oder `N/A` sind unzulässig.
- Weisen Sie Locking, I/O, CPU, Speicher, TempDB, Ergebnistransfer und bewusste Nebenwirkungen nur dann als nicht anwendbar aus, wenn dies aus dem Quellpfad begründbar ist.
- Geben Sie keine automatische DDL-, `KILL`-, Failover-, Repair- oder Forcing-Empfehlung.
- Verwenden Sie in Beispielen nur eindeutig synthetische `Example*`-Werte.
- Verlinken Sie Primärquellen direkt auf die relevante Microsoft-Produktseite; Drafts oder Sekundärblogs sind kein Ersatz.
- Weisen Sie externe Vertiefungen getrennt aus, beschreiben Sie diese als ergänzende Praxisperspektive und verwenden Sie sie nicht zur Begründung von Engine-, Versions- oder Berechtigungsaussagen.

Nicht jede Seite benötigt dieselbe Länge. Nicht anwendbare Punkte müssen jedoch ausdrücklich erklärt werden. Der Manifeststatus wird erst nach fachlichem Abgleich mit der kanonischen SQL-Quelle auf `DEEP_REVIEWED` gesetzt.
