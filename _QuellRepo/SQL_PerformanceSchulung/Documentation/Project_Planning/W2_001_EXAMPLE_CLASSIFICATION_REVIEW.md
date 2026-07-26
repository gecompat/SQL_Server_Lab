# W2-001 – Review der Bestandsbeispiel-Klassifikation

| Merkmal | Wert |
|---|---|
| Arbeitspaket | `W2-001` |
| Status | `VALIDATED` |
| Prüfdatum | 2026-07-25 |
| Referenzarchiv | `Presentations/old/Performance Grundlagen V-2024.zip` |
| SHA-256 | `78e3d1d708758d1115a066eca1df2c66d6f26ba57903b764c98e901506892041` |
| Bewertete Beispiele | 23 |
| Runtime historischer Skripte | nicht ausgeführt und nicht freigegeben |

## 1. Ergebnis

Alle 19 SQL-Dateien und vier TXT-Diagnoseabfragen des neutralisierten Referenzarchivs wurden inhaltlich geprüft. Die vollständige Matrix steht unter [`Documentation/Inventories/LEGACY_EXAMPLE_CLASSIFICATION.md`](../Inventories/LEGACY_EXAMPLE_CLASSIFICATION.md); der maschinenlesbare Vertrag steht in [`legacy_example_classification.json`](../Inventories/legacy_example_classification.json).

| Entscheidung | Anzahl |
|---|---:|
| `REUSE` | 0 |
| `REFACTOR` | 1 |
| `REBUILD` | 14 |
| `DIAGNOSTIC_ONLY` | 4 |
| `REMOVE` | 4 |

Kein historisches Skript erfüllt den aktuellen Demo-Vertrag ohne substanzielle Änderung. Diese Feststellung betrifft nicht den fachlichen Wert der enthaltenen Ideen. Sie verhindert, dass ungeschützte Datenbankanlage, globale Cacheeingriffe, feste Fremddatenbanken, nichtdeterministische Daten oder ungeprüfte Diagnoseausgaben in den aktiven Schulungsbestand übernommen werden.

## 2. Wesentliche Befunde

Der Isolation-Level-Entwurf enthält keine deterministische Sessionsteuerung; der dargestellte SNAPSHOT-Ablauf erzeugt den beabsichtigten Updatekonflikt nicht zuverlässig. Das Memory-Grant-Diagnoseskript verbindet wertvolle DMVs, verwendet jedoch eine nicht portable Kapazitätsformel und kann Login-, Programm-, Kontext- und SQL-Textdaten ausgeben. Die Wait-Stats-Abfrage bewertet kumulierte Serverwerte ohne Messintervall. Mehrere Workloadskripte verwenden `DBCC FREEPROCCACHE`, `DBCC DROPCLEANBUFFERS`, feste Datenbanknamen, öffentliche Beispieldatenbanken, Systemkataloge als Zeilengenerator oder nichtdeterministische `NEWID()`-/`RAND()`-Verteilungen.

Vier Dateien werden nicht migriert: das `FOR XML PATH`-Rezept, die allgemeine Funktionssammlung, das 149-KB-Skript zu Spaltenlimits und das gemischte Partitioned-Views-Skript. Ihre Einzelaspekte können nur als neu formulierte Bestandteile kanonischer Demos zurückkehren.

## 3. Migrationswirkung

`W2-A` priorisiert Isolation, zentrale DMV-Diagnose, Joinoperatoren, SARGability/Conversions, Parameter Sensitivity und Tipping Point. `W2-B` umfasst Buffer Pool, Partitionierung, korrelierte Subqueries, Ressourcenverbrauch, NULL-/Indexverhalten und Optimizerwissen. `W2-C` enthält APPLY, messbare JSON-Kosten und die Uniquifier-Vertiefung.

Die bereits validierte Demo `QRY-001` bleibt die kanonische SARGability-Implementierung. Der Altbestand erzeugt keine parallele Demo. Die vier `DIAGNOSTIC_ONLY`-Quellen werden erst in `W2-004` als versions-, berechtigungs-, scope- und privacybewusste Diagnosepfade neu veröffentlicht.

## 4. Technische Validierung

`Tests/Static/validate_w2_001_classification.py` öffnet das unveränderte Referenz-ZIP direkt und prüft für alle 23 Beispiele Archivpfad, Byteumfang und SHA-256. Zusätzlich werden eindeutige IDs, Entscheidungssummen, kanonische Demo-IDs, Source-Manifest-Synchronisierung, Backlogstatus und das Verbot direkter Ausführung geprüft.

Die Klassifikation ist daher `VALIDATED`. Dieser Status bedeutet ausschließlich, dass Analyse, Zuordnung und Migrationsentscheidung vollständig und konsistent sind. Er bedeutet nicht, dass eines der historischen Skripte auf SQL Server 2019, 2022 oder 2025 runtime-validiert wurde.

## 5. Nächster Schritt

Der nächste abhängige Verarbeitungsschritt ist `W2-002`: Für die priorisierte Gruppe `W2-A` werden feste Datenbank-/Objektabhängigkeiten, öffentliche Beispieldatenbanken, reale Bezeichnungen, globale Cacheeingriffe und nichtdeterministische Datenquellen entfernt. Erst danach beginnt `W2-003` mit dem Aufbau vollständiger Demo-Verträge.
