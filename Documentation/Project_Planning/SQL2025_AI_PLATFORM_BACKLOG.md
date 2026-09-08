# SQL Server 2025 KI-Plattform – Backlog

## Status

`AI-00 IMPLEMENTED`, `AI-05 IMPLEMENTED`, `AI-10A SUPPORTED`,
`AI-10B IN_PROGRESS`, `AI-20A SUPPORTED`, `AI-20B BACKLOG`, `AI-30A SUPPORTED`,
`AI-40A IMPLEMENTED`, `AI-40B IMPLEMENTED`, `AI-50A SUPPORTED`, `AI-60A SUPPORTED`,
`AI-60B BACKLOG`, `AI-70` bis `AI-80 BACKLOG`, `AI-90 IMPLEMENTED`.

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
Damit ist `AI-10A` `SUPPORTED`. Der echte HTTPS-Endpoint-Stub und die
Fehlerverträge sind umgesetzt; Dimensionswechsel und Re-Embedding bleiben als
`AI-10B` offen.

### AI-05 – Ollama-Vertragsgrundlage

- `Catalogs/ai-models.json` katalogisiert getrennte lokale Embedding-, lokale
  Generierungs- und Ollama-Cloud-Modelle mit Zweck, Dimension, Lizenz,
  Mindestversion und verpflichtender Live-Identitätsprüfung. Einträge bleiben
  bis zum jeweiligen nativen Nachweis bewusst `PLANNED`.
- Versionierte Verträge definieren den geheimnisfreien Endpointplan, das
  payloadfreie Runtimejournal und sanitisierte RAG-/Agentenergebnisse.
- Die CI-Auswahl koppelt Änderungen dieser Verträge an KI-Szenario-,
  Manifest- und Provider-Capability-Prüfungen. Diese Grundlage führt noch
  keinen Modellaufruf aus und ist kein Cloud-, Docker-, Podman- oder
  Hyper-V-Runtimenachweis.

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

`AI-90` ist in der bestehenden achtteiligen CLI-Struktur unter
„Datenbanken und Verbindungen → SQL Server 2025 KI → Geführte KI-Demos“
implementiert. Die vier Lernpfade delegieren an `vector-core-ci/1.0`, das
versionierte Golden Dataset, Golden-RAG beziehungsweise den read-only
Diagnose-Agenten. Retrieval-Metriken laufen ohne Modell- oder Netzwerkkosten;
RAG und Agent verwenden die kleinsten katalogisierten lokalen Modelle. Es
entstand weder ein separater Demo-Runtimekern noch eine Cloud-Abhängigkeit.

Der Endpoint-Slice von `AI-10B` ist implementiert: Die interne Endpointplanung
bindet ausschließlich katalogisierte Modelle, blockiert Cloud ohne expliziten
Egress und erzeugt stabile PlanKeys. Der gemeinsame Requestvertrag prüft
Embedding-Dimensionen sowie Generate-Antworten, begrenzt Retries und gibt bei
Timeout, Rate Limit oder ungültigen Antworten ausschließlich sanitisierte
Reason-Codes aus. Neben dem deterministischen Offline-Transport startet
`Invoke-AiHttpsEndpointStubAcceptance.ps1` einen echten flüchtigen
Loopback-TLS-Server. Dessen öffentliches Zertifikat und SHA-256-Pin sind an den
Endpointplan gebunden; Embed, Generate und ein echter HTTP-429-Retry laufen
über den normalen `HttpClient`, ohne den globalen Trust Store zu verändern.
Dimensionswechsel und ein kontrollierter Re-Embedding-Plan bleiben offen.

`AI-60A` stellt kataloggebundene Ollama-Cloud-Generation bereit. Der öffentliche
Aufruf verlangt eine nicht-interne Datenklasse und expliziten Cloud-Egress,
liest den festen Schlüssel `OLLAMA` erst nach `ShouldProcess` aus der lokalen
`.env` im Media Root, begrenzt Timeout, Tokens und Retries und verwendet keinen
Fallback. Der native Smoke am 2026-09-06 war mit `gpt-oss:120b`, einer
synthetischen Eingabe, einem Request und der exakten Antwort `OK` erfolgreich.
Eine breit lesbare Secret-Datei erzeugt vereinbarungsgemäß nur den sanitisierten
Warncode `AI_SECRET_FILE_ACL_BROAD_READ`. Ollama-Cloud-Embeddings sowie OpenAI
und Azure OpenAI sind als `AI-60B` weiterhin nicht implementiert.

`AI-20A` stellt denselben kataloggebundenen Aufruf für lokale Ollama-Endpunkte
bereit. Die getrennten nativen Docker- und Podman-Läufe waren am 2026-09-06
mit `ollama/ollama:0.11.10`, dynamischem Loopback-Port, live gebundenem Image-
und Modelldigest, `embeddinggemma:300m-qat-q4_0` mit 768 Dimensionen,
`gemma3:1b`, Container-Restart und vollständigem Cleanup erfolgreich. Diese
Controller-Lane verwendet ausschließlich Loopback-HTTP. Ein TLS-Gateway für
SQL Servers `CREATE EXTERNAL MODEL` und ein TLS-Gateway bleiben `AI-20B`. Der
providerneutrale Controller akzeptiert inzwischen verwaltete Hyper-V-SQL-2025-
Ziele für lokales RAG und read-only Diagnose; der native Nachweis ist wegen des
korrekt geschützten Einzelneustarts einer Testgruppen-VM noch `PARTIAL`.

`AI-40A` implementiert das deterministische, modellunabhängige Retrieval-Gate.
Es berechnet Recall@k, Precision@k, MRR und nDCG aus eindeutigen Dokument-IDs,
weist doppelte beziehungsweise ungültige IDs ab und liefert bei unterschrittenen
Schwellen maschinenlesbare Blocker. `AI-40B` ergänzt ein versioniertes,
synthetisches Golden Dataset. Frage, Dokumente, lokale Modellschlüssel, Top-k,
Schwellen, Dataset-Hash und Fall-ID werden vor Ausführung an den RAG-PlanKey
gebunden. Nur ein erfolgreiches `SqlServerLab.AiQueryResult/1.0` mit exakt
passender Bindung wird bewertet; Hash- oder Fallabweichungen scheitern vor der
Metrik. Der native Docker-Lauf war am 2026-09-07 einschließlich SQL-Suche,
Golden-Gate, Restart und Cleanup erfolgreich. Der getrennte Podman-Lauf erreichte
die RAG-Ausführung nicht, weil der einmalige lokale Modell-Pull nach 900 Sekunden
ablief; dessen Golden-Runtime-Nachweis bleibt deshalb offen.

`AI-30A` implementiert die lokale Controller-Orchestrierung für RAG. Dokumente
werden flüchtig mit dem katalogisierten 768-dimensionalen Ollama-Modell
eingebettet; SQL Server 2025 ordnet ausschließlich IDs und Vektoren per exakter
Cosine-Distanz in einer Tabellenvariable. Nur die ausgewählten Dokumenttexte
werden danach an das lokale Generierungsmodell gegeben. Es entstehen weder
dauerhafte SQL-Objekte noch Inhaltsjournale. Die getrennten nativen Docker- und
Podman-Läufe waren am 2026-09-06 einschließlich SQL-/Ollama-Restart, erwarteter
Top-Quelle und vollständigem Cleanup erfolgreich. Hybride Volltextsuche,
Aktualisierung/Löschung und Re-Embedding bleiben offen.

`AI-50A` implementiert den read-only Diagnose-Agenten mit vier festen
SELECT-Werkzeugen, maximal vier Aufrufen, Zeilen- und Kontextgrenzen sowie
lokaler Ollama-Zusammenfassung. Jeder Lauf erzeugt vor der ersten SQL-Mutation
ein inhaltsfreies Journal, legt eine zufällig benannte Least-Privilege-
SQL-Identität an und entfernt sie im `finally`. Modellantworten können weder
SQL noch weitere Werkzeuge auslösen. Die getrennten nativen Docker- und
Podman-Läufe waren am 2026-09-06 einschließlich echter Sichtrechte,
Login-Cleanup, Ollama-Restart und vollständigem Lab-Cleanup erfolgreich.
Ein echter Hyper-V-Controllerlauf belegte am 2026-09-07 RAG, Agent,
Login-Cleanup und Ollama-Restart; vollständige Provider-Capability folgt erst
nach dem noch offenen isolierten VM-Neustartnachweis.

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
