# RAG mit vorhandenem Host-Ollama

Stand: 2026-09-22. Der Controller verbindet lokale Embeddings mit exakter
SQL-Server-2025-Vektorsuche und lokaler oder ausdrücklich gewählter
HTTPS-Cloudgeneration.
`Invoke-SqlServerLabAiRag` bleibt für vorhandene lokale AdHoc- und Golden-v1-
Aufrufe unverändert voreingestellt. Der neue Slice erstellt keine dauerhaften
Retrievaltabellen und ist kein Re-Embedding-Executor.

## Öffentlicher Vertrag

```powershell
Invoke-SqlServerLabAiRag -RunId $runId -SaPassword $password `
    -Question 'Wie oft werden synthetische Sicherungen geprüft?' `
    -Document @(@{Id='backup-policy';Content='Synthetische Sicherungen werden täglich geprüft.'}) `
    -TopK 1 -EmbeddingModelKey ollama-embeddinggemma-latest `
    -GenerationModelKey ollama-gpt-oss-120b-cloud -GenerationLane cloud `
    -DataClassification synthetic-only -AllowCloudEgress `
    -SecretFilePath $secretFile -GenerationTimeoutSeconds 120 -GenerationRetryCount 0
```

Ein vollständig lokaler Nomic-v1.5-Aufruf verwendet denselben Vertrag:

```powershell
Invoke-SqlServerLabAiRag -RunId $runId -SaPassword $password `
    -Question 'Wie oft werden synthetische Sicherungen geprüft?' `
    -Document @(@{Id='backup-policy';Content='Synthetische Sicherungen werden täglich geprüft.'}) `
    -TopK 1 -EmbeddingModelKey ollama-nomic-embed-text-v1-5 `
    -GenerationModelKey ollama-qwen25-coder-7b-local -GenerationLane local
```

Für mehrsprachige 1024-dimensionale Embeddings kann derselbe Aufruf
`-EmbeddingModelKey ollama-bge-m3-latest` verwenden. Das Modell muss bereits im
laufenden lokalen Ollama vorhanden sein; der Controller lädt oder startet es nicht.

Die zusätzlichen Parameter gelten nur für AdHoc. `CaseId` bindet weiterhin die
lokalen Modelle des unveränderten Golden Datasets 1.0. Es gibt weder automatische
Cloudfallbacks noch eine Umdeutung eines lokal erreichbaren Cloudproxys als
lokales Modell. Cloud erhält die Frage und nur die ausgewählten Kontextdokumente.
Die deklarierte Datenklasse gilt für sämtliche übergebenen Inhalte;
`synthetic-only` und `public-or-redistributable` sind zugelassen. Fehlende oder
interne Klassifikation, fehlender Egress und falsche Modelllane blockieren vor
Ausführung. Inhalte werden nicht protokolliert oder persistiert.

`WhatIf` liest weder Secrets, Run-State, SQL noch Ollama. Danach wird der bestehende
Secretvertrag verwendet: festes `OLLAMA`-Feld aus einer lokalen `.env`, optional
im Media Root, ausschließlich für `https://ollama.com`. Der kurzlebige SecureString
wird auch bei Fehlern disposed. Eine breit lesbare Datei liefert weiterhin nur
`AI_SECRET_FILE_ACL_BROAD_READ`. Secrets und deren Pfade gehören nicht in Plan,
Ergebnis oder Git.

## Modell- und Transportgrenze

Der Katalogeintrag `ollama-embeddinggemma-latest` benennt
`embeddinggemma:latest`, 768 Dimensionen, mindestens Ollama 0.11.10 und Gemma Terms
of Use. Die [Ollama-Modellseite](https://ollama.com/library/embeddinggemma) dokumentiert
Tag, ungefähre Größe und Mindestversion; die
[Google-Modellkarte](https://ai.google.dev/gemma/docs/embeddinggemma/model_card)
belegt Dimension und Nutzungsbedingungen. Der Tag ist kein unveränderlicher
Digest. `ollama-nomic-embed-text-v1-5` benennt `nomic-embed-text:latest`, 768
Dimensionen, mindestens Ollama 0.1.26 und Apache-2.0. Die offizielle Ollama-
Tagliste weist `latest` und `v1.5` mit demselben Manifest aus. Die
[Nomic-Modellkarte](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5)
verlangt bei Retrieval `search_document: ` vor Dokumenten und `search_query: `
vor Fragen. Dasselbe Profil gilt für das bereits katalogisierte
`ollama-nomic-embed-text-v2-moe`. Das katalogisierte Profil `nomic-search` wendet beide Präfixe
rollengetreu an; `raw` lässt EmbeddingGemma- und BGE-M3-Eingaben unverändert. Das Profil ist
Teil des Endpoint-PlanKeys. Tatsächliche Version und Manifestdigest werden live
geprüft, nicht als allgemeine Hostidentität im Repository festgeschrieben.

`ollama-bge-m3-latest` benennt `bge-m3:latest` mit 1024 Dimensionen,
mehrsprachiger Eingabe, MIT-Lizenz und dem Rohtextprofil `raw`. Die
[offizielle Ollama-Modellseite](https://ollama.com/library/bge-m3) beschreibt
Mehrsprachigkeit und 8K-Kontext; die
[BAAI-Modellkarte](https://huggingface.co/BAAI/bge-m3) belegt Dimension und
Lizenz. SQL verwendet dadurch `VECTOR(1024)`. Die katalogisierte Mindestversion
0.34.2 ist der nachgewiesene Projektstand und keine behauptete Herstellergrenze.

Bei den vier vorhandenen Host-Embeddingmodellen oder expliziter
Cloudgeneration liest der Controller vor
Payload `/api/version`, `/api/tags` und `/api/show` am festen Loopback-Endpunkt.
Exakte Modellidentität, gültiger Digest, Mindestversion, Capability und
Embeddingdimension sind Pflicht. `remote_model` oder `remote_host` blockieren
die lokale Lane. Vor jedem Embedding und nach dessen gesamter Erzeugung wird
revalidiert; Drift blockiert SQL und Cloud. Bei lokaler Generierung im neuen
Hostpfad wird auch deren Bindung vor und nach dem Aufruf geprüft.

Metadaten und Payload folgen keinen HTTP-Redirects und verwenden auf Loopback
keinen Systemproxy. Der Controller zieht, entfernt oder entlädt keine Modelle
und startet keinen Hostdienst neu. Modellprüfungen ersetzen keine exklusive
Sperre eines fremd verwalteten Hostdienstes; eine gleichzeitige externe Mutation
zwischen zwei Probes ist nicht atomar ausschließbar.

Der portable `PlanKey` bindet Texte über Hashes, Modellpläne, Top-k, Lane,
Egress, Datenklassifikation und Requestlimits. `HostEmbeddingBinding` enthält
die tatsächlich verwendete Modellidentität ohne Endpointadresse; `ExecutionKey`
bindet Plan und Liveidentität. Vektoren müssen exakt dimensioniert und endlich
sein. SQL liefert eindeutige bekannte Dokument-IDs in der verlangten Anzahl.

## Grenzen und Nachweise

Höchstens 20 Dokumente und eine Frage mit jeweils maximal 8192 Zeichen; ein
Embeddingrequest je Dokument plus Frage, maximal ein Retry pro Request. Die
Generierung hat 512 Ausgabetokens, 1–230 Sekunden pro Versuch und 0–1 Retry.
Dies ist ein je Request geltendes Budget, kein providerweiter Kostenledger.
Metadatenrequests haben jeweils 15 Sekunden Timeout. Der native Nachweis wählt
für Cloudgeneration 120 Sekunden und Retry 0, insgesamt höchstens zwei
Cloudrequests. Die lokalen Nomic- und BGE-M3-Referenzen verwenden 180 Sekunden
ohne Retry.

`Tests/Static/Invoke-AiScenarioChecks.ps1` umfasst die fokussierten Host-/Cloud-
Checks einschließlich echter lokaler HTTP307-Characterization; insgesamt 107
Assertions bestanden auf dem finalen Stand. Die isolierte
`Tests/Integration/Invoke-AiRagExistingOllamaAcceptance.ps1` verwendet je Provider
einen neuen eigenen SQLrun, prüft feste Top-IDs vor/nach SQLrestart, unveränderte
Host-Tags und anschließend Container-/Volume-Abwesenheit. `PASS` erfolgt erst
nach vollständigem Cleanup. Die getrennten Podman- und Docker-Referenzen bestanden
am 2026-09-20 mit jeweils neun Assertions, zwei Cloudrequests, korrekten Top-IDs,
SQLrestart und unverändertem Hostmodellinventar. Cleanup jeweils: zwei Schritte,
null Fehler, Container-/Volume-Residueprüfung bestanden. Der erste Dockerlauf
scheiterte nach erfolgreichem Retrieval/Restart/Cleanup allein am ungeordneten
Inventarvergleich. Die API-Reihenfolge wurde danach im Harness kanonisiert und
mit Umordnungs-/Driftregression geprüft; der zweite Dockerlauf bestand mit
unverändertem Produktcode. Hyper-V bleibt für diesen kombinierten Slice offen.
Eine nichtleere
Cloudantwort beweist Inferenz, keine allgemeine Antwortqualität.

Am 2026-09-22 bestanden Docker und Podman den zusätzlichen vollständig lokalen
Nomic-v1.5-Nachweis getrennt mit jeweils neun Assertions. Beide Läufe banden
den Live-Digest, trafen vor SQLrestart `backup-policy`, danach `cleanup-policy`,
verwendeten lokale Qwen-Generierung und bestätigten ein unverändertes
Hostmodellinventar. Container und eigenes Volume wurden jeweils mit zwei
Cleanupschritten und null Fehlern entfernt. Der gemeinsame Controllercode
betrifft keine Hyper-V-Bereitstellung; dafür wurde kein neuer Hyper-V-Lauf
ausgewählt.

Am selben Tag bestanden Docker und Podman auch den vollständig lokalen
BGE-M3-Nachweis mit jeweils neun Assertions. Beide Läufe verwendeten
`VECTOR(1024)`, banden den Live-Digest, trafen dieselben festen Top-IDs vor und
nach SQLrestart und bestätigten das unveränderte Hostmodellinventar. Container
und eigenes Volume wurden jeweils mit zwei Cleanupschritten und null Fehlern
entfernt.

Die isolierte Golden-Containerabnahme lädt ihre beiden festen lokalen Modelle
in den eigenen, bind-gemounteten Ollama-Container. Pro Modell gilt das unveränderte
`TimeoutSeconds`-Budget von 60–1800 Sekunden als eine monotone Gesamtdeadline
über höchstens zwei Versuche einschließlich einer begrenzten Wartezeit. Nur HTTP
408, 429 und 5xx sowie typisierte Transport-/Abbruchfehler erhalten einen Retry;
4xx, unbekannte Fehler und jede Antwort ohne exakt `status: success` brechen
sofort mit einem redigierten `AI_RAG_MODEL_PULL_*`-Code ab. Die
[Ollama-Pull-API](https://github.com/ollama/ollama/blob/main/docs/api.md#pull-a-model)
beschreibt fortsetzbare abgebrochene Pulls und gemeinsam berichteten Fortschritt.
Der Harness verwendet deshalb keine neue Download- oder Host-Ollama-Lane.

Der interne [SQL-HTTPS-Docker-Referenzslice](AI_SQL_HTTPS_BRIDGE.md) belegt
SQL-seitiges `CREATE EXTERNAL MODEL`, TLS-Negative, Retrieval nach SQLrestart
und eigenes Cleanup. Allgemeiner Gatewaybetrieb bleibt `NOT_IMPLEMENTED`.
Das Ad-hoc-Profil ändert keine persistente Collection. Persistente
Modellmigration und die isolierte Hyper-V-Abnahme bleiben separate Nachweise.

Der separate [persistente synthetische Slice](AI_PERSISTENT_RETRIEVAL.md)
implementiert nun Initial-/Delta-Generationen auf Docker/Podman mit derselben
Host-Embeddingidentität, ohne Generierung. Docker und Podman sind getrennt nativ belegt; der gesonderte [Modellwechsel](AI_PERSISTENT_MODEL_MIGRATION.md) von Delta nach Nomic v2 MoE ist ebenfalls für beide Containerprovider nativ geprüft; der oben datierte AdHoc-Nachweis bleibt getrennt.
