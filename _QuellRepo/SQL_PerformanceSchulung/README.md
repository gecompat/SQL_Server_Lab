# SQL Server Performance Schulung

Dieses Repository enthält herstellernahe, reproduzierbare Schulungsunterlagen und Demonstrationen zur Performanceanalyse und -optimierung mit Microsoft SQL Server.

## Ziel

Die Schulung soll technische Ursache-Wirkungs-Zusammenhänge sichtbar machen. Jede Demonstration verbindet ein klar definiertes Lernziel mit reproduzierbarem Setup, messbarer Baseline, kontrollierter Problemursache, Diagnose-Evidenz, Gegenmaßnahme und Cleanup.

## Zielplattformen

- SQL Server 2019
- SQL Server 2022
- SQL Server 2025 als primäre Entwicklungs- und Demonstrationsplattform

Versions-, Compatibility-Level- und Edition-Abhängigkeiten werden je Demo ausdrücklich dokumentiert.

## Grundsätze

- T-SQL ist das bevorzugte Demonstrationsmittel.
- Infrastruktur wird nur eingesetzt, wenn T-SQL den Effekt nicht realistisch erzeugen kann.
- Alle Beispiele verwenden ausschließlich synthetische Labordaten.
- Präsentationen und weitere Schulungsartefakte enthalten keine nicht freigegebenen Firmeninformationen, Logos, Kontaktdaten oder internen Systembezeichnungen.
- Nur `Gerhard Pisch` ist als ausdrücklich freigegebene reale Namensangabe zulässig.
- Bildbasierte Logos und Markenkennzeichen werden zusätzlich zur Text- und Metadatensuche visuell geprüft.
- Risikoreiche Eingriffe sind eindeutig gekennzeichnet und ausschließlich für isolierte Laborsysteme vorgesehen.
- Aussagen werden gegen aktuelle Primärdokumentation geprüft; versionsabhängige Aussagen werden nicht pauschalisiert.

## Verbindliche Planung

- [Master-Umsetzungsplan](Documentation/Project_Planning/MASTER_IMPLEMENTATION_PLAN.md)
- [Gate-A-Review](Documentation/Project_Planning/GATE_A_REVIEW.md)
- [Gate-B-Review](Documentation/Project_Planning/GATE_B_REVIEW.md)
- [W2-001-Review der Bestandsbeispiel-Klassifikation](Documentation/Project_Planning/W2_001_EXAMPLE_CLASSIFICATION_REVIEW.md)
- [W2-007-Review der vier präzisierten Claims](Documentation/Project_Planning/W2_007_REFINE_CLAIMS_REVIEW.md)
- [Review der Welle-1-Framework-Basis](Documentation/Project_Planning/WAVE_1_FRAMEWORK_FOUNDATION_REVIEW.md)
- [Review der Welle-1-Daten-, Mess- und Ergebnisbasis](Documentation/Project_Planning/WAVE_1_DATA_MEASUREMENT_REVIEW.md)
- [Review der Welle-1-Orchestrierungs-, Telemetrie- und Runtimebasis](Documentation/Project_Planning/WAVE_1_ORCHESTRATION_RUNTIME_REVIEW.md)
- [Review der SQL-Server-Runtime-Matrix](Documentation/Project_Planning/SQL_SERVER_RUNTIME_MATRIX_REVIEW.md)
- [Konflikt- und Entscheidungslog](Documentation/Project_Planning/CONFLICT_AND_DECISION_LOG.md)
- [Planergänzung zur Qualität der Schulungsunterlagen](Documentation/Project_Planning/PRESENTATION_QUALITY_INTEGRATION_PLAN.md)
- [Baseline-Review der vorhandenen Präsentationen](Documentation/Reviews/PRESENTATION_BASELINE_REVIEW_2024.md)
- [Priorisierte Inhalts- und Evidenzlücken](Documentation/Reviews/CONTENT_GAP_ANALYSIS.md)
- [Quellenmanifest der Schulungsartefakte](Documentation/Inventories/SOURCE_MANIFEST.md)
- [Klassifikation der historischen SQL- und Diagnosebeispiele](Documentation/Inventories/LEGACY_EXAMPLE_CLASSIFICATION.md)
- [Folien- und Aussagenregister](Documentation/Inventories/SLIDE_STATEMENT_REGISTER.md)
- [Curriculumarchitektur und Lernzielmodell](Documentation/Curriculum/CURRICULUM_ARCHITECTURE.md)
- [Traceability-Matrix](Documentation/Curriculum/TRACEABILITY_MATRIX.md)
- [Gate-B-Ausführungs-Traceability](Documentation/Curriculum/GATE_B_TRACEABILITY.md)
- [Kritische Aussagenprüfung](Documentation/Reviews/CRITICAL_CLAIMS_REVIEW.md)
- [Projektweites Quellenregister](Documentation/Research/SOURCE_REGISTER.md)
- [Primärquellenregister für W0](Documentation/Research/PRIMARY_SOURCES_W0.md)
- [Primärquellen für die Welle-1-Framework-Basis](Documentation/Research/FRAMEWORK_SOURCES_W1.md)
- [Quellenbasis der SQL-Server-Runtime-Matrix](Documentation/Research/SQL_SERVER_RUNTIME_MATRIX_SOURCES.md)
- [Primärquellen der Gate-B-Pilotdemos](Documentation/Research/GATE_B_PILOT_SOURCES.md)
- [Terminologie- und Schreibstandard](Documentation/Standards/TERMINOLOGY_AND_STYLE_STANDARD.md)
- [Privacy- und Metadaten-Prüfverfahren](Documentation/Quality/PRIVACY_METADATA_REVIEW_PROCEDURE.md)

## Repository-Struktur

| Pfad | Zweck |
|---|---|
| `.ai/` | Verbindlicher Projektkontext, Entscheidungen, Roadmap und AI-Arbeitsregeln |
| `Assets/` | Firmenneutrale, wiederverwendbare Abbildungen und Quelldateien |
| `Documentation/` | Curriculum, fachliche Vertiefungen, Demo-Katalog, Reviews und Recherche |
| `Demos/` | Modulare, bevorzugt T-SQL-basierte Demonstrationen |
| `Infrastructure/` | Reproduzierbare Docker-, Podman- und Hyper-V-Laborszenarien |
| `Presentations/` | Firmenneutrale Präsentationsquellen und Exporte |
| `Tests/` | Statische Prüfungen und SQL-Server-Versionsmatrix |
| `Tools/` | Unterstützende, nicht demo-spezifische Werkzeuge |

## Sicherheitsstufen für Demos

- **Grün:** normale, lokal begrenzte T-SQL-Demo.
- **Gelb:** kontrollierte CPU-, RAM-, TempDB-, I/O- oder Concurrency-Last.
- **Rot:** Instanzkonfiguration, Cache-Eingriff, Dienstneustart oder Infrastrukturmanipulation; nur in einer isolierten Lab-Instanz.

## Status

Welle 0, Gate A und Gate B sind validiert. Die Framework-Arbeitspakete `FWK-001` bis `FWK-012` sind in offiziellen Microsoft-Linux-Containern auf SQL Server 2019, 2022 und 2025 mit Compatibility Levels 150, 160 und 170 runtime-validiert.

Gate B umfasst die validierten Piloten `QRY-001`, `OPT-002`, `CON-004` und `OPT-013`. Der Workflowlauf `30108023315` führte jede Demo je Version zweimal vollständig aus und bestätigte 24 erfolgreiche Demoläufe einschließlich markergeprüftem Cleanup nach jedem Lauf.

`W2-007` ist validiert: Die Folien 32, 34, 42 und 43 unterscheiden Cache-Schlüssel von Invalidierung, führen IQP-Voraussetzungen versions- und konfigurationsbezogen, vermeiden eine feste Table-Variable-Größenheuristik und berücksichtigen Interleaved Execution sowie Scalar UDF Inlining. Sichtbarer Text, Speaker Notes, Quellen und Traceability sind synchronisiert.

`W2-001` ist validiert: Alle 19 historischen SQL-Dateien und vier Diagnoseabfragen sind inhaltlich und hashbasiert klassifiziert. Es existiert kein direkter `REUSE`-Kandidat; 14 Quellen werden neu aufgebaut, eine wird refaktoriert, vier werden ausschließlich als Diagnosequellen weitergeführt und vier werden nicht migriert.

Der nächste kritische Pfad ist `W2-002`: feste Datenbank-, Objekt- und Umgebungsabhängigkeiten der priorisierten Migrationskandidaten entfernen. Parallel bleiben Query-Store-/Extended-Events-Diagnosepfade, Teilnehmerunterlagen und weitere Curriculum-Demos offen. Der Gesamtstatus des Projekts bleibt bis zur vollständigen Inhalts- und Releaseabnahme `PLANNED`.

## Lizenz

Dieses Projekt verwendet eine eigene Lizenz und ist nicht als Open-Source-Projekt lizenziert. Maßgeblich ist [LICENCE.md](LICENCE.md).
