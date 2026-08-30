# SQL Server 2025 Vector- und Embedding-Umgebung – Backlog

## Status

`BACKLOG` – SQL_Server_Lab katalogisiert SQL Server 2025 und besitzt
providerneutrale SQL-, Software-, Secret-, Lifecycle- und Testverträge. Ein
ausführbares Vector-/Embedding-Szenario mit lokalem oder externem Modell ist
noch nicht implementiert. Reihenfolge und Priorität richten sich nach dem
kanonischen Entwicklungs- und Ausführungsplan.

## Ausgangslage

SQL Server 2025 kann Vektoren im nativen Datentyp `VECTOR(n)` speichern und
über `VECTOR_DISTANCE` exakt vergleichen. Embeddings entstehen dadurch nicht
automatisch: `AI_GENERATE_EMBEDDINGS` benötigt ein registriertes Modell. Dieses
kann über einen HTTPS-Endpunkt wie Ollama, OpenAI oder Azure OpenAI erreichbar
sein oder unter SQL Server 2025 auf Windows lokal als ONNX-Modell über den AI
Runtime Host laufen.

SQL Server liefert kein fertiges Embedding-Modell mit. Modell, Tokenizer,
Runtime, Dimension, Lizenz, Herkunft und Integrität müssen deshalb explizit
aufgelöst und nachgewiesen werden. Lokale ONNX-Ausführung ist derzeit ein
Windows- und Preview-Pfad mit SQL Server Machine Learning Services; sie darf
nicht als Linux-Container-Capability ausgewiesen werden.

Approximate Vector Search über `CREATE VECTOR INDEX` und `VECTOR_SEARCH` ist
unter SQL Server 2025 ebenfalls Preview und besitzt andere Einschränkungen als
der reguläre Vector-Datentyp und die exakte Distanzberechnung. Der erste
ausführbare Kern darf deshalb nicht von der Preview-Indexfunktion abhängen.

## Ziel

Ein Manifest oder Package soll eine kleine, reproduzierbare SQL-Server-2025-
Testumgebung für semantische Suche erstellen können. Sie enthält synthetische
Dokumente, nachvollziehbare Chunks, Embeddings mit gebundener Modellidentität,
eine `VECTOR(n)`-Spalte und live verifizierte Ähnlichkeitsabfragen.

Das Szenario bietet drei getrennte Lanes:

1. `VECTOR_CORE` – providerneutraler SQL-Kern mit vorberechneten, fest
   versionierten Testvektoren und exakter Suche ohne Modellruntime;
2. `LOCAL_ONNX` – lokale Embedding-Erzeugung innerhalb des SQL-Server-2025-
   Windows-Gasts über AI Runtime Host, ohne Ollama, Cloud oder API-Token;
3. `EXTERNAL_EMBEDDINGS` – Embedding-Erzeugung über einen gesicherten lokalen
   Ollama-Endpunkt oder einen ausdrücklich konfigurierten Cloud-Endpunkt.

Ollama ist damit eine austauschbare Embedding-Variante und keine zwingende
Abhängigkeit des Vector-Kerns.

## Gemeinsamer Daten- und SQL-Vertrag

- Die Testdaten sind synthetisch, klein, lizenzklar und per Content Hash
  gebunden. Reale Kunden-, Diagnose-, Prompt- oder Chatdaten sind
  ausgeschlossen.
- Textaufteilung, Chunk-Größe, Überlappung, Normalisierung und Reihenfolge sind
  versionierter Intent. Ein Modellaufruf darf nicht unbemerkt eine andere
  Chunk-Semantik erhalten.
- Die aufgelöste Modelldimension bestimmt `VECTOR(n)`. Ein Dimensionskonflikt
  blockiert vor Tabellenmutation; Vektoren werden weder abgeschnitten noch
  aufgefüllt.
- Index- und Suchtexte verwenden dieselbe Modellidentität, Version,
  Tokenizerkonfiguration und Dimension.
- Ein Modell-, Tokenizer-, Dimensions- oder relevanter Normalisierungswechsel
  erzeugt einen expliziten Re-Embedding- und gegebenenfalls Index-Rebuild-Plan.
  Bestehende Vektoren werden nicht still mit einem neuen Modell vermischt.
- Der portable State enthält ModelKey, Dimension, Metrik, Dataset-/Chunk-
  Digests, PlanKey und sanitisierte Evidence, aber keine Prompts mit sensiblen
  Daten, Hostpfade, Tokens oder Credentials.
- Exakte Suche über `VECTOR_DISTANCE` ist die verpflichtende Baseline.
  Approximate Search und Vector Index sind eine getrennt aktivierbare Preview-
  Capability und kein allgemeines `READY`-Kriterium.

## Lane 1 – Providerneutraler Vector Core

`VECTOR_CORE` benötigt weder Ollama noch ONNX oder Internetzugriff. Der Ablauf:

1. erstellt eine SQL-Server-2025-Datenbank mit Compatibility Level 170;
2. importiert ein kleines, versioniertes Dokument-/Vector-Fixture;
3. speichert die Vektoren in einer typisierten `VECTOR(n)`-Spalte;
4. prüft Konvertierung, Dimension und relevante Vector-Metadaten;
5. führt exakte Cosine-, Dot-Product- und Euclidean-Distanzfälle aus;
6. bestätigt eine erwartete Top-k-Reihenfolge mit definierten Toleranzen;
7. beweist Persistenz über Stop, Start und vollständigen Restart.

Diese Lane ist für SQL Server 2025 unter Docker, Podman und Hyper-V/Windows
getrennt ausführbar. Sie ist der kleinste Nachweis für den SQL-Vector-Vertrag
und bleibt auch verfügbar, wenn kein Modell bezogen werden darf.

## Lane 2 – Lokales ONNX unter Windows

`LOCAL_ONNX` erzeugt Embeddings lokal ohne API-Endpunkt und ohne Cloud-Egress.
Sie ist ausschließlich zulässig, wenn der Resolver folgende Capabilities live
bestätigt:

- SQL Server 2025 auf Windows;
- SQL Server Machine Learning Services und funktionsfähiger Launchpad-/AI-
  Runtime-Host;
- explizit aktivierte Preview- und External-AI-Runtime-Konfiguration;
- katalogisierte, hashgeprüfte ONNX-Runtime- und Tokenizer-Bibliotheken;
- katalogisiertes ONNX-Embedding-Modell samt `model.onnx`, `tokenizer.json`,
  Dimension, Lizenz und zulässiger Verwendung;
- minimale, scopegebundene Dateisystemrechte für das Runtime-Servicekonto.

Freie Modellpfade, frei geladene DLLs und unbekannte Modellrepositories werden
vor jeder Gastmutation abgelehnt. Modell, Runtime und Tokenizer sind
ausführbarer Drittcode und durchlaufen Artifact-Trust-, Lizenz-,
Vulnerability- und Ownership-Prüfung. Cleanup entfernt nur run-eigene
Installationen; gemeinsam katalogisierte Baselines bleiben erhalten.

Der Referenznachweis läuft auf einem eindeutigen SQL-Server-2025-Windows-Child-
Slot unter Hyper-V. Linux-, Docker- und Podman-SQL-Instanzen melden diese Lane
solange fail-closed als nicht unterstützt, bis Microsoft und das Projekt eine
eigene reale Capability belegen.

## Lane 3 – Ollama und externe Embedding-Endpunkte

### Lokales Ollama

- Docker und Podman stellen SQL Server und Ollama als getrennte, run-eigene
  Container in einem isolierten Netzwerk bereit. Beide Provider benötigen
  getrennte native Evidence.
- Ein kleines CPU-taugliches Embedding-Modell ist der Referenzfall; GPU ist
  eine optionale Capability und keine Voraussetzung für den ersten Slice.
- Ollamas lokale Standard-API benötigt üblicherweise kein Token und verwendet
  HTTP. SQL Server bindet External Models nur über HTTPS. Deshalb stellt der
  Workflow einen scopegebundenen TLS-Gateway-Endpunkt bereit und installiert
  dessen CA reproduzierbar im SQL-Trust-Store.
- Modell-Weights, Manifest und Layers werden digest-, lizenz- und
  herkunftsgebunden im Artifact-Vertrag geführt. Ein Modellname allein ist
  keine stabile Identität.
- Hyper-V darf Ollama später als Dienst oder Container in einer geeigneten
  Windows- oder Linux-VM bereitstellen, benötigt dafür aber einen eigenen
  realen Installations-, Netzwerk-, TLS-, Ressourcen- und Cleanup-Nachweis.

### Cloud-Endpunkte

- Ollama Cloud, OpenAI und Azure OpenAI sind optionale, explizit ausgewählte
  Providerbindungen. Ihre Verfügbarkeit, API-Formate, Modelle, Dimensionen,
  Kosten und Quotas werden live geprüft und nicht aus einem Plan behauptet.
- SQL_Server_Lab erzeugt keinen Ollama-, OpenAI- oder Azure-Account und mintet
  keine fremden API-Keys. Ein User-Gate kann zur offiziellen Key-Verwaltung
  führen, nimmt danach ausschließlich eine lokale Secret-Referenz entgegen
  und prüft den Kandidaten vor dem ersten Datenversand.
- Lokales Ollama benötigt keinen Token. Direkter Zugriff auf die Ollama-Cloud-
  API benötigt einen vom Benutzer erzeugten und widerrufbaren API-Key. Ein
  gültiger Key ist noch kein Nachweis, dass das gewählte Embedding-Modell als
  Cloud-Modell verfügbar ist; ein echter Embed-Probe ist verpflichtend.
- Tokens werden nur über den bestehenden Secret Provider injiziert. Sie
  erscheinen weder im Manifest noch in Plan, Command Line, Prozessliste,
  State, Logs, XEvents, Fehlertexten oder Receipts.
- Cloud-Egress ist standardmäßig aus. Vor Aktivierung zeigt der Plan Provider,
  Zielhost, Modell, versandte Datenklasse, geschätzte Operationen sowie bekannte
  Kosten-/Quota-Grenzen und verlangt eine ausdrückliche Egress-Policy.
- Es gibt weder automatische Umschaltung von lokal auf Cloud noch stillen
  Provider-Fallback bei Ressourcenmangel, Rate Limit, Modellfehler oder
  fehlendem Token. Ein Wechsel erzeugt einen neuen Plan und gegebenenfalls
  vollständiges Re-Embedding.
- Cloud-Smokes sind capability- und secretgebunden opt-in. Fehlende persönliche
  Tokens dürfen die lokalen Pflichtgates nicht blockieren und werden niemals
  durch Repository- oder CI-Secrets vorgetäuscht.

## Lifecycle, Readiness und Recovery

Der gemeinsame Workflow führt in idempotenter Reihenfolge mindestens aus:

1. SQL-Version, Betriebssystem, Provider, Preview-Intent, Ressourcen, Egress,
   Artifact-Trust, Secret-Referenzen und Modellcapabilities read-only prüfen;
2. SQL-2025-Instanz sowie je nach Lane ONNX-Artefakte oder lokalen
   Embedding-Endpunkt scopegebunden bereitstellen;
3. Prozess-, Modell-, TLS-, Authentifizierungs- und Embed-Readiness live
   bestätigen;
4. Datenbank, Rollen, erforderliche Konfiguration, External Model und Tabellen
   idempotent erstellen;
5. synthetische Dokumente chunken, Embeddings erzeugen oder Fixtures laden und
   Dimension sowie Zeilenzuordnung bestätigen;
6. exakte Such-Postconditions ausführen und erst danach `READY` veröffentlichen;
7. eine aktivierte Preview-Lane getrennt indexieren und Approximate Search samt
   Einschränkungen prüfen.

Resume und Repair beginnen mit Live-Probes. Partiell erzeugte Embeddings werden
journalisiert, deterministisch fortgesetzt oder kompensiert. Retry respektiert
Providerfehler und Rate Limits, erzeugt aber keine ungebremsten Kosten. Abbruch
und Cleanup entfernen ausschließlich run-eigene SQL-Objekte, Credentials,
Trust-Artefakte, Modellbindungen, Container, Volumes und Gastinstallationen.

## Sicherheits- und Datenschutzvertrag

- `CREATE EXTERNAL MODEL`, `AI_GENERATE_EMBEDDINGS`, Secret-Nutzung und
  Preview-Aktivierung erhalten getrennte Least-Privilege-Rollen.
- Die Aktivierung externer REST-Endpunkte oder AI Runtimes erfolgt nur für eine
  aufgelöste Lane und wird bei Cleanup beziehungsweise Repair nach
  Eigentumsvertrag behandelt.
- Lokale Endpunkte werden nicht ungeplant an Host- oder externe Interfaces
  veröffentlicht. Erforderliche Ports laufen über den Portallocator.
- Zertifikatsfehler, unbekannte CAs, Hostname-Mismatch und HTTP-Downgrade führen
  fail-closed zum Abbruch.
- Vor Cloud-Aufrufen werden ausschließlich synthetische beziehungsweise
  ausdrücklich freigegebene Daten zugelassen. Der Plan macht sichtbar, dass
  Text-Chunks den lokalen Trust-Bereich verlassen.
- Extended Events und HTTP-Diagnostik werden auf Status, Latenz,
  Providerklassifikation und sanitisierte Fehler begrenzt; Header, Token und
  vollständige Payloads werden nicht persistiert.
- Modell- und Runtime-Artefakte gelten als ausführbarer Drittinhalt. Digests,
  Signatur beziehungsweise Herkunft, Lizenz und bekannte Risiken sind vor
  Freigabe zu prüfen.

## Erwarteter Umsetzungsumfang

1. Einen versionierten Vector-/Embedding-Intent mit Lane, Provider, Modell,
   Dimension, Metrik, Chunking, Preview- und Egress-Policy definieren.
2. Modell-, ONNX-Runtime-, Tokenizer- und Ollama-Artefakte katalogisieren und
   gegen den bestehenden Artifact-, Software- und Secret-Vertrag auflösen.
3. Providerneutrale SQL-Handler für Vector-Core, Chunking, External Model,
   Embedding, Re-Embedding, Suche, Observation und Cleanup implementieren.
4. Windows-/Hyper-V-Handler für Machine Learning Services, AI Runtime Host,
   Dateirechte und lokalen ONNX-Pfad ergänzen.
5. Docker- und Podman-Handler für lokalen Ollama-Service, Modellvolume,
   Netzwerk, TLS-Gateway, Trust und Ressourcenlimits getrennt anbinden.
6. Ein allgemeines User-Gate für optionale externe API-Key-Referenzen und
   read-only Credential-/Endpoint-Probes verwenden, ohne Provideraccounts zu
   verwalten.
7. Preview-Vector-Index/`VECTOR_SEARCH` als getrennte Capability mit eigener
   Known-Limitation- und Abnahmematrix führen.
8. Benutzerreferenz, Manifestbeispiele, Kataloge, Architektur-, Security-,
   Privacy-, Netzwerk-, Storage- und Cleanup-Dokumentation gemeinsam
   aktualisieren.

## Abnahmekriterien

- `VECTOR_CORE` besteht mit demselben Fixture und derselben erwarteten
  Distanz-/Ranking-Semantik getrennte reale SQL-2025-Läufe unter Docker, Podman
  und Hyper-V/Windows einschließlich Restart und Cleanup.
- `LOCAL_ONNX` erzeugt auf einem realen SQL-2025-Windows-Child-Slot ohne
  Netzwerkzugriff Embeddings, deren Dimension, endliche Werte, Zeilenzuordnung
  und erwartete semantische Rangfolge bestätigt sind.
- Lokales Ollama erzeugt unter Docker und Podman getrennt Embeddings über einen
  vertrauenswürdigen HTTPS-Endpunkt; HTTP, falsche CA und falscher Hostname
  werden jeweils fail-closed abgelehnt.
- Ein optionaler Cloud-Smoke kann nach explizitem Egress und gültiger lokaler
  Secret-Referenz denselben semantischen Workflow ausführen. Fehlendes Token,
  Rate Limit, nicht verfügbares Modell oder Quota erzeugt einen sanitisierten,
  fortsetzbaren Befund ohne lokalen Fallback oder Secret-Leak.
- Ein Modell- oder Dimensionswechsel blockiert Mischbetrieb und erzeugt einen
  nachvollziehbaren Re-Embedding-/Rebuild-Plan.
- Wiederholung, Resume und Repair erzeugen keine doppelten Chunks, Vektoren,
  External Models, Credentials, Modelle oder Runtime-Ressourcen.
- Stop, Start und vollständiger Restart erhalten Daten und Modellbindung; die
  danach ausgeführten Live-Probes liefern erneut die erwartete Suche.
- Preview-Index und Approximate Search werden nur bei explizitem Intent
  aktiviert, als Preview ausgewiesen und getrennt von der exakten Baseline
  berichtet.
- Cleanup entfernt ausschließlich run-eigene SQL-, Runtime-, Trust-, Netzwerk-
  und Storage-Ressourcen. Katalogisierte Shared Artifacts sowie fremde lokale
  oder Cloud-Ressourcen bleiben unverändert.
- Logs, State, Receipts, Testausgaben und exportierte Verbindungsdaten bestehen
  Privacy- und Secret-Scanner; kein API-Key oder sensibler Text wird
  versioniert oder persistiert.

## Nicht Teil des ersten Vertical Slice

- allgemeine Chat-, Agenten- oder LLM-Plattform;
- automatisches Erstellen von Provideraccounts, Abonnements oder API-Keys;
- produktiver RAG-Service oder ungeprüfte Verarbeitung realer Dokumente;
- verpflichtende GPU-, CUDA- oder Hyper-V-GPU-Passthrough-Unterstützung;
- automatischer Providerwechsel oder Kostenoptimierung durch stillen
  Cloud-Fallback;
- Behauptung von Linux-ONNX- oder stabiler Vector-Index-Capability ohne aktuelle
  Herstellerfreigabe und reale Projektnachweise;
- Modelltraining oder Fine-Tuning.

## Bei der Umsetzung erneut zu prüfende Herstellerquellen

- Microsoft-Dokumentation zu `VECTOR`, `VECTOR_DISTANCE`, `VECTOR_SEARCH`,
  `CREATE VECTOR INDEX`, `CREATE EXTERNAL MODEL`, `AI_GENERATE_CHUNKS` und
  `AI_GENERATE_EMBEDDINGS` für den verwendeten SQL-2025-CU-Stand;
- aktuelle SQL-Server-2025-Known-Issues für ONNX, AI Runtime Host und Vector
  Index;
- Ollama-Dokumentation zu `/api/embed`, lokaler Authentifizierung,
  Cloud-API-Keys und tatsächlich verfügbaren Embedding-Modellen;
- Lizenz-, Herkunfts-, Digest- und Securityangaben jedes gewählten Modells,
  Tokenizers und Runtime-Artefakts.
