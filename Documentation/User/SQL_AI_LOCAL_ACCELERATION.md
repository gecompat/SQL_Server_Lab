# Lokale beschleunigte Embeddings für SQL Server 2025

Dieses How-to beschreibt den erforschten Zielpfad. Es installiert derzeit
nichts automatisch und ist kein nativer Projektnachweis. Der bestehende
[SQL-HTTPS-Referenzslice](../Architecture/AI_SQL_HTTPS_BRIDGE.md) ist dagegen
mit Docker und Ollama nativ belegt.

## Wann dieser Pfad verwendet wird

SQL Server 2025 kann ein Embeddingmodell mit `CREATE EXTERNAL MODEL`
registrieren und durch `AI_GENERATE_EMBEDDINGS` aufrufen. Für `llama-server`
und OpenVINO Model Server passt `API_FORMAT='OpenAI'` mit dem Endpunkt
`/v1/embeddings` beziehungsweise `/v3/embeddings`. Ollama verwendet weiterhin
`API_FORMAT='Ollama'` und `/api/embed`.

Der Accelerator wird von der Inferenzruntime gewählt, nicht von SQL Server.
Die SQL-Definition allein beweist daher keine NPU- oder GPU-Nutzung.

Vor einer Live-Probe erzeugt das neue read-only Cmdlet einen gebundenen Plan:

```powershell
Get-SqlServerLabAiExternalModelPlan `
  -Backend LlamaCppOpenVino -Accelerator NPU `
  -Location 'https://host.docker.internal:11435/v1/embeddings' `
  -ExternalModelName LocalNpuEmbedding -RuntimeModel bound-model `
  -Dimension 768 -ModelSha256 $modelHash -RuntimeSha256 $runtimeHash `
  -ServerCertificateSha256 $certificateHash
```

Ein gültiger Plan bleibt absichtlich `NOT_PROBED` mit
`EvidenceStatus=CONFIGURATION_ONLY`. Erst ein späterer Endpunkt-, Dimensions-
und Runtime-Nachweis darf daraus ausgeführte CPU-, GPU- oder NPU-Evidence
machen. Das Cmdlet installiert nichts und ändert weder Trust Store, Firewall,
Hosts-Datei noch Dienste.

## Empfohlene Topologie

```text
SQL Server 2025
  -> HTTPS + Credential
  -> llama-server mit eigener TLS-Unterstützung
  -> OpenVINO NPU/GPU oder CUDA/ROCm
```

Wenn die Runtime nur HTTP anbietet:

```text
SQL Server 2025
  -> HTTPS
  -> kurzlebiger, authentisierter Gateway
  -> fest gebundener Loopback-Endpunkt
  -> OpenVINO Model Server oder andere lokale Runtime
```

Eine Änderung der Hosts-Datei ersetzt kein Routing. Ein Container kann einen
nur an `127.0.0.1` des Hosts gebundenen Dienst erst erreichen, wenn die
jeweilige Docker-/Podman-Hostroute das tatsächlich ermöglicht. Das muss mit
dem später verwendeten DNS-Namen, Port und Zertifikat geprüft werden.

## Windows: llama.cpp mit OpenVINO-NPU

Voraussetzungen sind ein passender Intel-NPU-Treiber, ein OpenVINO-Build von
`llama.cpp`, ein geeignetes Embedding-GGUF sowie ein operationseigenes
Zertifikat und eine API-Key-Datei. Modell, Quantisierung und Pooling müssen aus
vertrauenswürdigen Modellmetadaten stammen.

Beispiel für eine bewusst manuelle Vorprüfung:

```powershell
$env:GGML_OPENVINO_DEVICE = 'NPU'
& 'C:\Pfad\zu\llama-server.exe' `
  --model 'C:\Pfad\zum\embedding-model.gguf' `
  --embedding `
  --pooling mean `
  --ctx-size 512 `
  --host 127.0.0.1 `
  --port 11435 `
  --ssl-key-file 'C:\Pfad\run\server-key.pem' `
  --ssl-cert-file 'C:\Pfad\run\server-cert.pem' `
  --api-key-file 'C:\Pfad\run\api-keys.txt'
```

`mean` und `512` sind Platzhalter. Das konkrete Modell kann anderes Pooling,
Präfixe oder Grenzen verlangen. Für Intel-NPU nennt llama.cpp `Q4_0` als
primär unterstützte Quantisierung und empfiehlt einen kleinen Kontext. Der
Server muss mit TLS-Unterstützung gebaut worden sein.

Read-only prüfen:

```powershell
curl.exe --cacert C:\Pfad\run\ca.pem https://localhost:11435/health
curl.exe --cacert C:\Pfad\run\ca.pem https://localhost:11435/v1/embeddings `
  -H 'Authorization: Bearer <nur-lokal-einsetzen>' `
  -H 'Content-Type: application/json' `
  -d '{"model":"bound-model","input":"Wie oft wird ein Backup erstellt?","encoding_format":"float"}'
```

Der spätere automatisierte Pfad darf den Schlüssel weder in Prozessargumente
noch Logs schreiben. Er übergibt ihn über eine restriktiv lesbare Datei oder
stdin und löscht die operationseigenen Dateien nach bestätigtem Prozessende.

## SQL Server registrieren

Das folgende Muster ist erst nach erfolgreicher TLS-, Auth-, Modell- und
Dimensionsprüfung zulässig:

```sql
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<kurzlebiges Testsecret>';

CREATE DATABASE SCOPED CREDENTIAL [https://host.docker.internal:11435]
WITH IDENTITY = 'HTTPEndpointHeaders',
     SECRET = '{"Bearer":"<lokaler API-Key>"}';

CREATE EXTERNAL MODEL LocalNpuEmbedding
WITH (
    LOCATION = 'https://host.docker.internal:11435/v1/embeddings',
    API_FORMAT = 'OpenAI',
    MODEL_TYPE = EMBEDDINGS,
    MODEL = 'bound-model',
    CREDENTIAL = [https://host.docker.internal:11435],
    PARAMETERS = '{"sql_rest_options":{"retry_count":0}}'
);

DECLARE @embedding vector(768) =
    AI_GENERATE_EMBEDDINGS(N'Wie oft wird ein Backup erstellt?'
                           USE MODEL LocalNpuEmbedding);
SELECT @embedding;
```

Hostname und Dimension müssen dem Zertifikat und Modell entsprechen. Ein
Container verwendet nicht automatisch `localhost` des Hosts. Für Podman ist
`host.containers.internal` ein eigener, noch nativ nachzuweisender Pfad.

## OpenVINO Model Server als Alternative

OVMS kann Embeddings als OpenAI-kompatible API bereitstellen und NPU explizit
wählen. Ein dokumentierter NPU-Kandidat ist Qwen3 Embedding:

```text
ovms --pull --model_repository_path <models> \
  --source_model OpenVINO/Qwen3-Embedding-0.6B-int8-ov \
  --pooling LAST --task embeddings --target_device NPU --max_length 1000
```

OVMS bietet selbst keine REST-/gRPC-Transportverschlüsselung. Der REST-Port
darf deshalb nur auf Loopback oder in ein isoliertes Netz gebunden werden und
SQL greift über den scopegebundenen HTTPS-Gateway oder einen gleichwertig
geprüften Reverse Proxy zu. Für SQL ist anschließend `/v3/embeddings` mit
`API_FORMAT='OpenAI'` zu prüfen.

## GMKtec EVO-X2 mit Ryzen AI Max+ 395 unter Linux

Für die NPU-Lane werden AMD-XRT, `amdxdna` und Ryzen AI Software verwendet.
Erste Inventar- und Installationsevidence:

```bash
source /opt/xilinx/xrt/setup.sh
xrt-smi examine
```

Die aktuelle AMD-Anleitung unterstützt NPU-only LLMs sowie BF16-Encoder unter
Linux. Für SQL fehlt noch ein projektsicherer OpenAI-Embeddingserver; dieser
Pfad benötigt daher einen begrenzten Adapter und HTTPS-Gateway.

Für einen früher ausführbaren Serverpfad unterstützt ROCm die integrierte
Radeon-8060S-Architektur `gfx1151`. Ein HIP-Build von `llama-server` stellt
direkt `/v1/embeddings` bereit. Diese Evidence heißt ausdrücklich `GPU`, nicht
`NPU`. Modell, ROCm-/llama.cpp-Version und bekannte `gfx1151`-Fehler werden vor
der Abnahme fixiert.

## Ultra 9 275HX mit Intel-Grafik und RTX 5080

Auf diesem System werden vier explizite Läufe verglichen:

1. OpenVINO mit `GGML_OPENVINO_DEVICE=NPU`;
2. OpenVINO/SYCL auf der Intel-Grafik;
3. CUDA auf der RTX 5080;
4. CPU als Baseline.

Alle Läufe verwenden dieselben Texte, dasselbe Modellformat soweit technisch
vergleichbar, dieselbe Dimension und dieselben SQL-Rankingassertions. Ein
NPU-Erfolg benötigt einen Runtimebeleg für das Zielgerät. Für die RTX 5080
werden aktuelle Upstream-Regressionsmeldungen zu CUDA/Blackwell vor der
Versionswahl erneut geprüft; Vulkan kann als separat benannte Vergleichslane
hinzukommen.

## Sichere Abnahme

Vor der Kennzeichnung `SUPPORTED` müssen mindestens bestehen:

- Health- und Embeddingprobe mit exakter Dimension und nur endlichen Werten;
- erwartete deutsche Rangfolge im direkten Endpunkt und in SQL;
- tatsächliche NPU-/GPU-Geräteausführung;
- falsche CA, falscher SAN, HTTP und falscher API-Key werden abgewiesen;
- fremdes Modell und Dimensionsabweichung werden vor Persistenz abgewiesen;
- Runtime- und SQL-Neustart ändern Modell-/Gerätebindung nicht;
- Prozess, Port, Zertifikat, Credential, External Model und eigener SQL-Run
  werden vollständig bereinigt.

Die priorisierte Umsetzung und weitere Hardwarepfade stehen im
[Acceleration-Backlog](../Project_Planning/AI_EXTERNAL_MODEL_ACCELERATION_BACKLOG.md).
