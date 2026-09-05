# SQL Server 2025 KI-Plattform – Backlog

## Status

`AI-00 IMPLEMENTED`, `AI-10A SUPPORTED`, `AI-10B BACKLOG`, `AI-20` bis
`AI-90 BACKLOG`.

Dieser Backlog ist der übergeordnete SQL-zentrierte KI-Plan. Der
[Vector- und Embedding-Backlog](SQL2025_VECTOR_EMBEDDING_BACKLOG.md) bleibt
der technische Teilplan für Vector Storage, Embeddings, ONNX, Ollama und
optionale Cloud-Endpunkte. Planungsstatus und statische Prüfung sind kein
Docker-, Podman-, Hyper-V- oder Modell-Runtime-Nachweis.

## Zielbild und Grenzen

- SQL Server bleibt Daten-, Retrieval-, Sicherheits- und Nachweiszentrum.
- Docker und Podman bilden den local-first Linux-Pfad. Hyper-V folgt für die
  Windows-ONNX-Lane und spätere Provider-Parität.
- Entwicklung und CI haben Vorrang. Schulung/Demo und betriebsnahes RAG
  verwenden später dieselben versionierten Szenarien und Assertions.
- Der Pflichtpfad benötigt weder Internet, Modell-Download noch GPU.
- Produktive Schreibagenten, Training/Fine-Tuning, Kundendaten und eine
  allgemeine Nicht-SQL-Agentenplattform bleiben außerhalb des Scopes.

## Implementierte Grundlage

### AI-00 – Plattformverträge

- `ai.models[]`, `ai.policies` und `ai.scenarios[]` sind Bestandteil des
  Manifestvertrags. Modellwerte binden Zweck, Provider, Variante, optionale
  Endpoint-/Credential-Referenz, Dimension, Timeout und begrenzte Retries.
- Der aufgelöste `SqlServerLab.AiIntent/1.0` enthält portable PlanKeys, aber
  weder Secretwerte noch Endpoint-URLs, Runtimepfade oder Inhaltsprotokolle.
- `SqlServerLab.AiScenario/1.0` bindet Dataset, Modellzuordnung, T-SQL-Schritte,
  Assertions, Evaluation und Cleanup über IDs, Versionen und SHA-256.
- `Get-SqlServerLabAiScenario` projiziert einen geheimnis- und pfadfreien Plan.
  `Invoke-SqlServerLabAiScenario` revalidiert ihn, journalisiert vor Mutation
  und führt nur hashgebundene Dateien innerhalb des Modul-Roots aus.

### AI-10 – Deterministischer Vector-Core

Das Szenario `vector-core-ci/1.0` verwendet ausschließlich synthetische
deutsche Dokumente und feste dreidimensionale Vektoren. Es prüft SQL Server
2025, Compatibility Level 170, `VECTOR(3)`, exakte Cosine-Distanz, Top-k,
`AI_GENERATE_CHUNKS`, Dataset-/Modellbindung und automatisches Cleanup.

Docker und Podman deklarieren die Capability `sql2025-vector-core` getrennt.
Die nativen Läufe über
`Tests/Integration/Invoke-AiVectorCoreAcceptance.ps1` waren am 2026-09-05 für
beide Provider erfolgreich, einschließlich Szenario- und Provider-Cleanup.
Damit ist `AI-10A` `SUPPORTED`. Ein Endpoint-Stub, Dimensionswechsel und
Re-Embedding bleiben als `AI-10B` offen.

## Priorisierte Lieferwellen

| Welle | Ziel | Abnahmegrenze |
|---|---|---|
| AI-10B | Deterministischer Embedding-/Generation-Endpoint-Stub, Dimensionskonflikt, Timeout, Rate Limit, ungültige Antwort, Retry und verbotenes Fallback | Offline Static- und Integration-Gate ohne Modellruntime |
| AI-20 | Run-eigener TLS-Gateway und Ollama; digestgebundenes CPU-Embedding- und kompaktes Instruct-Modell; getrennte Modell- und Netzwerklifecycles | Eigener Docker- und Podman-Smoke mit Restart, Resume und Cleanup |
| AI-30 | Semantische, Volltext- und hybride Suche; RAG mit Chunk-Quellen und kontrolliertem „nicht ausreichend belegt“ | Quellenbindung, Aktualisierung, Löschung und Re-Embedding nachgewiesen |
| AI-40 | Golden Dataset und blockierende Retrieval-Metriken wie Recall@k, Precision@k, MRR und nDCG | Deterministische Metriken blockieren CI; Modell-Judge bleibt informativ |
| AI-50 | Read-only SQL-Agent über katalogisierte, parameterisierte Diagnose-Prozeduren | DDL, DML, freie SQL-Ausführung, Secretzugriff und unbekannte Tools scheitern |
| AI-60 | Opt-in OpenAI, Azure OpenAI und Ollama Cloud | SecretRef, Datenklassifikation, Egress, Budget und eigener Provider-Smoke; kein Fallback |
| AI-70 | Lokales ONNX unter Windows/Hyper-V und spätere Python-External-Language-Brücke | Jede OS-/Provider-/Runtimekombination besitzt eigenen Restart- und SQL-Nachweis |
| AI-80 | Preview-ANN, Skalierung, Ausfall, Backup/Restore, Observability und Kosten | Exakte Suche bleibt Referenz; Preview-Ergebnisse werden separat ausgewiesen |
| AI-90 | Geführte Vector-, Retrieval-, RAG- und Agent-Demos | Gleiche Szenariopakete und Assertions wie Entwicklung/CI |

## Sicherheits- und Betriebsvertrag

- `fallback` ist standardmäßig `disabled`; ein Modellwechsel erfolgt nie still.
- Cloudmodelle erfordern `egress: explicit` und eine Credential-Referenz. Der
  Secretwert bleibt außerhalb Manifest, Desired State, Journal und Ergebnis.
- Szenariopakete akzeptieren keine absoluten Pfade oder `..`; Dataset und jeder
  SQL-Schritt werden vor Nutzung als kanonischer UTF-8-/LF-Inhalt erneut
  gehasht. Dadurch bleiben Identität und PlanKey über Windows- und Linux-
  Checkouts stabil.
- Ein Journal trennt Szenariofehler von Cleanupfehlern. Fehlgeschlagenes
  Cleanup ergibt sichtbar `RECOVERY_REQUIRED`.
- Read-only Agenten erhalten später einen eigenen SQL-Benutzer und ausschließlich
  allowlist-basierte Werkzeuge mit Parameter-, Zeit-, Zeilen- und Größenlimits.

## Definition of Done

Eine Welle wechselt erst auf `SUPPORTED`, wenn Schema, Resolver, PlanKey,
Secret-Redaction, negative Fälle und der jeweils betroffene native Provider
erfolgreich geprüft wurden. Docker, Podman, Hyper-V, Cloud, ONNX, External
Languages und ANN sind getrennte Nachweise. Ein grüner Vector-Core-Lauf ist
kein Embedding-, Generation-, RAG- oder Agentennachweis.

## Primärquellen

- [Vector-Datentyp](https://learn.microsoft.com/en-us/sql/t-sql/data-types/vector-data-type?view=sql-server-ver17)
- [`VECTOR_DISTANCE`](https://learn.microsoft.com/en-us/sql/t-sql/functions/vector-distance-transact-sql?view=sql-server-ver17)
- [`AI_GENERATE_CHUNKS`](https://learn.microsoft.com/en-us/sql/t-sql/functions/ai-generate-chunks-transact-sql?view=sql-server-ver17)
- [`CREATE EXTERNAL MODEL`](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-external-model-transact-sql?view=sql-server-ver17)
- [Ollama Embeddings](https://docs.ollama.com/capabilities/embeddings)
