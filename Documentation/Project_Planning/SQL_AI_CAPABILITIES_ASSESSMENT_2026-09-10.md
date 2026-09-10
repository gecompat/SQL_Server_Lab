# Bewertung weiterer SQL-KI-Fähigkeiten und des Modellcaches

| Merkmal | Wert |
|---|---|
| Status | `validated` (Bewertung; keine neue Modell-/SQL-Ausführung) |
| Stand | 2026-09-10 |
| Quellstand | `1180457` |
| Auftrag | TLS-Gateway, ONNX, ANN, zusätzliche Cloudanbieter und Modellcache aus dem [Arbeitsplan](AUTONOMOUS_DEVELOPMENT_WAVE_2026-09-10.md) |

## Grundlage und Entscheidung

Der [KI-Plattformbacklog](SQL2025_AI_PLATFORM_BACKLOG.md) und der
[Vector-Vertrag](SQL2025_VECTOR_EMBEDDING_BACKLOG.md) bleiben maßgeblich.
Der vorhandene [Endpointvertrag](../../Private/AiEndpoint.ps1) bindet lokale
Ollama-Aufrufe beziehungsweise explizite Ollama-Cloud-Generation. Sein lokaler
Controller-HTTP-Pfad und der HTTPS-Teststub belegen keinen SQL-seitigen
External-Model-Aufruf. RAG verwendet derzeit flüchtige Inhalte und exakte
SQL-Distanzsuche; der Re-Embedding-Plan führt noch keine Generationenumschaltung
aus. Diese bestehenden Grenzen dürfen die neuen Bewertungen nicht verdecken.

Priorität haben die offenen isolierten Podman-/Hyper-V-Abnahmen und persistentes
Retrieval. Die folgenden Erweiterungen werden danach nur in ihrem begrenzten
SQL-Scope umgesetzt. **M** steht für einen begrenzten Vertrag mit eigener
Abnahme, **L** für mehrere gekoppelte Trust-, Runtime- oder Datenverträge.
Diese relativen Angaben sind keine gemessenen Zeit- oder Preisversprechen.

## SQL-seitiger TLS-Gateway

Der Nutzen ist ein tatsächlicher `AI_GENERATE_EMBEDDINGS`-Aufruf aus SQL Server
an das lokale Modell. Als erster späterer Slice wird eine eigene Docker-SQL-2025-
Instanz mit run-eigenem Gateway und Ollama vorgesehen; Podman und Hyper-V folgen
mit getrenntem Netzwerk-/Trust-/Restart-Nachweis. Aufwand L.

SQL-Endpoint, Zertifikatsidentität, Laufzeit, Modell und Dimension werden vor
Mutation gebunden. Zertifikat und private Schlüssel bleiben im lokalen Scope;
Trust wird nur im eigenen SQL-Ziel eingerichtet. Hostname, Gültigkeit und
Vertrauenskette müssen funktionieren. Ein global abgeschalteter Zertifikatscheck
ist keine Lösung. Der Gateway akzeptiert nur den gebundenen Backend-/Requestpfad
mit Zeit-, Größen- und Parallelitätsgrenzen; Redirects und freie Weiterleitung
dürfen keinen anderen Endpoint erschließen.

Der nächste vollständige Lauf registriert ein eigenes External Model, erzeugt
synthetische Embeddings in SQL und prüft Dimension, Inhaltseigenschaften und
Suchergebnis. Falsche CA, falscher Hostname, abgelaufenes Zertifikat, ausgefallener
Backend und Dimensionsabweichung müssen sichtbar scheitern. Nach SQL-/Gateway-/
Modellneustart wird erneut geprüft; Cleanup entfernt nur eigene SQL-Objekte,
Credentials, Zertifikate und Runtime-Ressourcen. Hauptrisiken sind überbreiter
Trust, Exposition des Modellservers und unvollständiger Secret-Cleanup.

## Lokales ONNX

Der Nutzen ist SQL-seitige Embedding-Erzeugung ohne externen Modelldienst.
Entscheidung: ein isolierter Windows-/Hyper-V-SQL-2025-Child-Slot als spätere
Referenz, keine Linux-/Containerfreigabe. Voraussetzung sind der belegte
Machine-Learning-/External-Runtime-Pfad, ein konkret unterstützter SQL-Build,
gebundene Runtime-/Tokenizer-Bibliotheken und ein freigegebenes kleines Modell.
Modell, Bibliotheken, Lizenz, Quelle und erwartete Digests gehören zusammen.
Aufwand L; ausführbarer Drittinhalt und servicegebundene Dateirechte sind die
wichtigsten Risiken.

Der nächste Lauf prüft zunächst unveränderte Readiness und danach echte SQL-
Embeddings sowie exakte Suche auf synthetischen Texten. Veränderte Modellbytes,
fehlende Bibliothek, unzulässiger Pfad und falsche Dimension blockieren.
Dienst-/VM-Neustart, Entfernung eigener SQL-/Modell-/Rechtebindungen und
unveränderte gemeinsame Baselines gehören zur Abnahme. Diese Bewertung wählt
kein ungeprüftes Modell und installiert keine DLL.

## ANN und Vektorindizes

Der Nutzen muss gegenüber der exakten Suche gemessen werden. ANN bleibt eine
separate Preview-Lane, bis konkreter SQL-Build und Indexversion live gebunden
sind. Cloud-Dokumentation darf nicht auf die lokale SQL-Installation übertragen
werden. Aufwand M für eine begrenzte Vergleichslane, L mit persistenten
Generationen, Aktualisierung und Wiederherstellung.

Der nächste Schritt verwendet ein festes synthetisches Dataset und identische
Queryvektoren für exakte Suche und ANN. Recall@k, Filterkorrektheit, deterministische
Tie-Behandlung der Referenz, Laufzeit, Aufbaukosten und Speicher werden getrennt
berichtet. Messwiederholungen sind vorab begrenzt; ein schnellerer Einzelaufruf
reicht nicht. Indexversionsabhängige Mindestdatenmenge und DML-/Filtergrenzen
werden aus dem tatsächlichen Zielstand abgeleitet. Stale-Ergebnisse dürfen keine
erfolgreiche Generationenumschaltung vortäuschen. Restart, Backup/Restore und
Cleanup müssen für diese Lane separat bestehen. Exakte Suche bleibt die Referenz.

## Zusätzliche Cloudanbieter

Der bestehende Ollama-Cloud-Generierungspfad ist kein OpenAI-, Azure-OpenAI-
oder Cloud-Embedding-Nachweis. Ohne konkreten Bedarf und gebundenes Kosten-/
Egresslimit werden diese Anbieter jetzt nicht aktiviert. Der lokale Betrieb
bleibt vollständig nutzbar. Aufwand M je klar begrenztem Provideradapter und
zusätzliche native Kosten nach dem ausdrücklich gewählten Testumfang.

Bei späterem Bedarf wird genau ein Anbieter, Endpoint, Modell und Zweck
ausgewählt. Aktuelle API-/Modellfähigkeit und Preis-/Quotagrenzen müssen vor
dem ersten Request bestätigt sein. Secret-Referenz, synthetische Datenklasse,
Request-/Token-/Zeitbudget und Egress werden gemeinsam gebunden; unbekannte
Kosten oder Dimensionen blockieren. Ein gültiger Key beweist keine Embedding-
Capability. Der erste kleine Smoke enthält eine echte erlaubte Antwort und
gezielte Offline-Negativfälle für Rate Limit, Timeout und ungültige Antwort.
Es gibt keinen automatischen Anbieterwechsel. Konten, Abonnements und produktive
Datenverarbeitung gehören nicht zu diesem Auftrag.

## Modellcache

Ein gemeinsamer persistenter Cache wird in dieser Welle bewusst nicht eingeführt.
Der [Ollama-Container-Test](../../Tests/Integration/Invoke-AiOllamaContainerAcceptance.ps1)
lädt Modelle in den eigenen Container und prüft Live-Digests; das ist noch kein
verwalteter gemeinsamer Blob-/Lease-Vertrag. Der dokumentierte Podman-Pull-Timeout
begründet eine Untersuchung, beweist aber weder die Ursache noch einen sicheren
Cachegewinn. Die Kataloggrößen sind Schätzwerte, keine gemessenen Downloadkosten.

Vor Übernahme sind erwartete Modell-/Manifest-/Layer-Digests, Lizenz und
Runtimekompatibilität zu binden. Ein späterer Cache braucht ein eigenes
registriertes Root, atomare Veröffentlichung vollständig geprüfter Inhalte,
Quarantäne bei Abbruch, exklusive Writer, lesende Leases, Größenlimits und
referenzgebundene Entfernung. Kein gemeinsamer beschreibbarer Modellspeicher
zwischen fremden Runs. Aufwand L; falsche Modellidentität, Teilinhalte und
Löschen noch verwendeter Blobs sind die wesentlichen Risiken.

Der nächste Schritt ist zunächst eine begrenzte Messung des geänderten
Podman-Referenzlaufs mit erfolgreichem Pull und Cleanup. Nur bei nachgewiesenem
wiederholtem Downloadengpass folgt eine eigene Cache-Implementierungswelle mit
Cold-/Warm-Vergleich, beschädigtem Blob, konkurrierendem Reader, Prozessabbruch
und Lease-geschütztem Cleanup. Die begründete Nichtübernahme schließt die
Bewertungsaufgabe ab, nicht den separat offenen Podman-RAG-Nachweis.

## Quellen und Prüfgrenze

Die Herstellerquellen wurden am 2026-09-10 gelesen. Die genannten nächsten
Schritte sind Projektentscheidungen; es wurde kein neuer SQL-/Modell-/Cloudlauf
ausgeführt und keine Laufzeitfähigkeit hochgestuft.

- Microsoft beschreibt [External Models einschließlich Ollama und lokalem ONNX](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-external-model-transact-sql?view=sql-server-ver17). Der lokale ONNX-Referenzpfad gilt für Windows und benötigt Machine Learning Services; Modell- und Bibliotheksvertrauen liegt beim Betreiber.
- [Vektorindizes](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-vector-index-transact-sql?view=sql-server-ver17) bleiben für SQL Server 2025 Preview. Die dort beschriebene neueste Indexversion ist gegenwärtig auf Azure SQL Database und SQL database in Fabric begrenzt.
