# Lokale beschleunigte Embeddings für SQL Server 2025

Dieses How-to trennt implementierte Discovery und Windows-Start von noch
offenen Backend-/Modellkombinationen. Es installiert nichts automatisch.
Für die übrigen Backend-/Modellpaare besteht kein allgemeiner nativer Projektnachweis.
Der bestehende
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
$plan = Get-SqlServerLabAiExternalModelPlan `
  -Backend LlamaCppOpenVino -Accelerator NPU `
  -Location 'https://host.docker.internal:11435/v1/embeddings' `
  -ExternalModelName LocalNpuEmbedding -RuntimeModel bound-model `
  -Dimension 768 -ModelSha256 $modelHash -RuntimeSha256 $runtimeHash `
  -ServerCertificateSha256 $certificateHash
```

Ein gültiger Plan bleibt absichtlich `NOT_PROBED` mit
`EvidenceStatus=CONFIGURATION_ONLY`. Der Endpunkt kann anschließend ohne
Änderung des Host-Truststores geprüft werden. Für eine private CA wird deren
Zertifikat nur im aktuellen Prozess als Custom Root verwendet:

```powershell
$rootCa = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
  [IO.File]::ReadAllText('C:\Pfad\run\ca.pem'))
$apiKey = Read-Host 'Lokaler API-Key' -AsSecureString
$receipt = $plan | Test-SqlServerLabAiExternalModelEndpoint `
  -ApiKey $apiKey -TrustedRootCertificate $rootCa

$sqlPlan = Get-SqlServerLabAiExternalModelSqlPlan `
  -Plan $plan -EndpointReceipt $receipt -DatabaseName AiLab

$sqlPreflight = Test-SqlServerLabAiExternalModelSqlPreflight `
  -SqlPlan $sqlPlan -RunId $runId

$credentialSecret = Read-Host 'HTTP-Header-Secret für SQL' -AsSecureString
$sqlApply = Invoke-SqlServerLabAiExternalModelSqlApply `
  -SqlPlan $sqlPlan -PreflightReceipt $sqlPreflight -RunId $runId `
  -CredentialSecret $credentialSecret

$sqlEmbedding = Test-SqlServerLabAiExternalModelSqlEmbedding `
  -SqlPlan $sqlPlan -ApplyReceipt $sqlApply -RunId $runId

$sqlCleanup = Remove-SqlServerLabAiExternalModelSql `
  -SqlPlan $sqlPlan -ApplyReceipt $sqlApply -RunId $runId
```

Bei einem öffentlich oder bereits systemweit vertrauten Zertifikat entfällt
`TrustedRootCertificate`; der im Plan gebundene Leaf-SHA-256 wird trotzdem
exakt geprüft. Die Probe sendet genau einen festen synthetischen Text und
liefert weder Text noch Embeddingvektor oder API-Key zurück. Ein Erfolg heißt
`ENDPOINT_VERIFIED`: TLS, exakter Runtime-Modellname, OpenAI-Antwortform,
endliche numerische Werte und Dimension sind live bestätigt. Runtime-
Binärdatei, Modelldatei und tatsächliche CPU-/GPU-/NPU-Ausführung bleiben bis
zu getrennten Nachweisen offen. Ein fehlender oder abweichender Modellname
blockiert mit `AI_EXTERNAL_MODEL_RUNTIME_MODEL_MISMATCH`.

Der SQL-Planer akzeptiert standardmäßig nur ein höchstens fünf Minuten altes,
unverändertes Receipt. Er beschreibt den SQL-17-, Datenbankberechtigungs- und
Database-Master-Key-Preflight, Credential, External Model, Katalogprüfung und
die umgekehrte Cleanupfolge. Ein aus dem Plan-Key abgeleiteter Tabellenname ist
für das spätere SQL-seitige Ownership-Receipt reserviert; eine vorhandene Tabelle
mit diesem Namen blockiert den Preflight. Der Planer verbindet sich nicht mit
SQL Server und nimmt kein Secret entgegen.

Der anschließende Preflight verbindet sich ausschließlich mit dem eigenen,
rungebundenen Docker-/Podman-SQL-Ziel. Er prüft SQL 2025, eine Benutzer-
Datenbank und deren exakte Identität,
`ONLINE`/`READ_WRITE`, Database Master Key, `CONTROL` und
`CREATE EXTERNAL MODEL` sowie freie Credential- und Modellnamen. Sein
hashgebundenes Receipt enthält weder Secret noch SQL-Text und führt kein DDL aus.

Der anschließende Apply-Befehl revalidiert Plan, Preflight-Receipt, den laufenden
Docker-/Podman-Container und die Datenbank-GUID. Vor der ersten SQL-Mutation
schreibt er ein geheimnisfreies, atomisches Journal. Eine einzelne
`XACT_ABORT`-Transaktion erstellt zuerst eine planabgeleitete Ownership-Tabelle,
danach das Database Scoped Credential und das External Model und bestätigt alle
drei Postconditions. Die Ownership-Zeile bindet zusätzlich `credential_id` und
`external_model_id`; ein später unter gleichem Namen ersetztes Objekt gilt nicht
mehr als eigenes Cleanup-Ziel. Das Credential-Secret wird nur als `SecureString`
angenommen und weder in Receipt noch Journal geschrieben. Bei verlorener Antwort
wird kein DDL blind wiederholt: `-Resume` liest den gebundenen SQL-Zustand und
akzeptiert nur die vollständige Ownership-Postcondition; Teilzustände melden
`AI_EXTERNAL_MODEL_SQL_APPLY_RECOVERY_REQUIRED`.

Die anschließende SQL-Embedding-Probe verlangt das unveränderte Apply-Receipt
und Journal im Zustand `APPLIED`. Unter demselben lokalen Journal-Lock und einem
SQL-Shared-AppLock revalidiert sie Datenbank-GUID, Ownership-Zeile sowie die
gespeicherten Credential- und External-Model-Katalog-IDs. Dann führt SQL Server
genau einen festen, parametrisierten `AI_GENERATE_EMBEDDINGS`-Aufruf aus. Das
sanitisierte Receipt bestätigt Dimension, `float32` und einen endlichen,
nichtleeren Vektor, enthält aber weder Testtext, SQL-Text, Norm noch Vektor.

Der Cleanup-Befehl revalidiert Plan, Apply-Receipt, Live-Binding, Journal und
Datenbank-GUID. Er akzeptiert nur die vollständige, exakt eigene SQL-
Ownership-Postcondition. Danach löscht eine einzelne `XACT_ABORT`-Transaktion
External Model, Database Scoped Credential und Ownership-Tabelle in dieser
Abhängigkeitsreihenfolge. Das Journal wird vor der Mutation auf
`CLEANUP_PENDING` gesetzt. `-Resume` bestätigt nach einem unbekannten Ausgang
nur vollständige Abwesenheit oder wiederholt bei weiterhin vollständig
intaktem Eigentum; Teilzustände bleiben `AI_EXTERNAL_MODEL_SQL_CLEANUP_RECOVERY_REQUIRED`.

Der Apply-Receipt allein bestätigt keinen Embeddingaufruf. Das getrennte
Embedding-Receipt schließt diese Postcondition, belegt aber weder SQL-Neustart
noch Acceleratorpfad. Der Cleanup-Receipt belegt die SQL-seitige Abwesenheit.
Ein nativer SQL-2025-End-to-End-Lauf bleibt für diese neue Probe separat offen.

Plan und Probe installieren nichts und ändern weder Truststore, Firewall,
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

### Kuratierte Generationsmodelle bei Bedarf laden

Der Repositorykatalog enthält drei nicht gesperrte, vom Hersteller Qwen
veröffentlichte GGUF-Dateien. Quelle und Revision sind unveränderlich gebunden;
Größe, SHA-256, Apache-2.0-Lizenz und GGUF-Magic werden vor der atomaren Ablage
unter `MediaRoot/AI/Models` geprüft. Ein vorhandener Cache wird bei jeder
Auswahl vollständig revalidiert. Es gibt keinen Quellen- oder Modellfallback.

```powershell
Get-SqlServerLabLlamaCppModel

$selected = Save-SqlServerLabLlamaCppModel `
  -Id qwen3-4b-q4_k_m `
  -MediaRoot D:\Lab_Base `
  -Confirm:$false

$selected.Path
```

| Stufe | Katalog-ID | Datei | Zweck |
|---|---|---:|---|
| compact | `qwen2.5-1.5b-instruct-q4_0` | ca. 1,07 GB | kleinste offizielle Q4_0-Alternative für CPU und experimentelle OpenVINO-Pfade |
| balanced | `qwen3-4b-q4_k_m` | ca. 2,50 GB | ausgewogene lokale Generationslast für eine diskrete GPU oder ausreichend schnellen CPU-/GPU-Speicher |
| performance | `qwen3-8b-q4_k_m` | ca. 5,03 GB | größere Generationslast für die RTX- oder Ryzen-Max+-Klasse mit ausreichendem Speicher |

Diese Stufen sind Kapazitätsempfehlungen und keine Benchmarks. Die Dateien sind
Instruct-/Generationsmodelle. Der vorhandene
`Start-SqlServerLabLlamaCppRuntime` ist ein streng geprüfter Embeddingpfad und
übernimmt diese Auswahl deshalb nicht automatisch. Die lokal vorhandenen
Dateien `Llama-3.2-1B-Instruct-Q4_0.gguf` und
`Qwen_Qwen3-0.6B-Q4_0.gguf` können weiterhin explizit über ihren Pfad verwendet
werden; ohne gebundene Herausgeberquelle und SHA-256 werden sie nicht als
vertrauenswürdiger Katalogdownload ausgegeben.

Die spätere automatische Gerätewahl vergleicht nur vollständig benchmarkte,
für denselben Modell-/Workloadvertrag geeignete CPU-, NPU-, Einzel-GPU- und
Mehr-GPU-Kandidaten. Die Katalogstufe ersetzt diese Messung nicht.

### Benchmarkgebundene Gerätewahl

`Get-SqlServerLabAiComputeInventory` liest den lokalen Host ohne Runtime-Start.
Unter Windows verwendet es CIM für CPU und Displaygeräte sowie die vorhandene
`ComputeAccelerator`-PnP-Klasse für NPUs. Unter Linux liest es `/proc/cpuinfo`,
DRM-sysfs und `/sys/class/accel`. Rohe PnP-Instanz- und PCI-Buspfade werden nur
zum Deduplizieren verwendet und nicht ausgegeben. Wenn CPU-, GPU- oder
NPU-Coverage nicht verfügbar ist, bleibt das Receipt `INCOMPLETE` und besitzt
keinen verwendbaren Inventarhash.

```powershell
$inventory = Get-SqlServerLabAiComputeInventory
$runtimes = Get-SqlServerLabLlamaCppRuntime -SearchRoot $runtimeRoots
$runtimeCapabilities = Get-SqlServerLabAiRuntimeCapability `
  -Inventory $inventory `
  -Runtime $runtimes
$candidateSet = Get-SqlServerLabAiComputeCandidate `
  -Inventory $inventory `
  -RuntimeCapability $runtimeCapabilities.Capabilities
```

Jede Runtime-Fähigkeit begrenzt Gerätearten, Hersteller-IDs, minimale und maximale Gerätezahl,
gemischte Gerätearten sowie Eligibility und Blocker. `VendorIds = @('*')` erlaubt
alle Hersteller; der Wildcard darf nicht mit einzelnen Hersteller-IDs gemischt werden. Innerhalb dieser Grenzen
werden alle Kombinationen gebildet. Mehr als 64 Kandidaten werden sichtbar
abgewiesen; die Funktion schneidet die Kandidatenmenge nie still ab. Die
`Get-SqlServerLabAiRuntimeCapability` bindet alle unmittelbaren Binärdateien
jedes erkannten llama.cpp-Pakets an einen gemeinsamen Runtimehash. Es leitet
eine CPU-Baseline sowie vorhandene CUDA-, ROCm-, Vulkan-, SYCL- und
OpenVINO-Lanes ab. CUDA wird auf NVIDIA, ROCm auf AMD sowie SYCL und
OpenVINO-GPU/-NPU auf Intel begrenzt. Fehlende passende Geräte bleiben mit
Blocker sichtbar. `FILES_HASHED_NOT_EXECUTED` ist noch kein Ausführungs- oder
Performancebeleg; erst vollständige Benchmarks machen die Auto-Auswahl möglich.

`Get-SqlServerLabAiComputeSelection` setzt `Auto` als Standard um. Jeder
Kandidat benennt Backend, Runtime-SHA-256 und ein Set aus einem oder mehreren
CPU-, NPU- oder GPU-Geräten. Damit sind einzelne Beschleuniger, mehrere
Grafikkarten und gemischte Gerätesätze ausdrückbar. Ungeeignete Kandidaten
bleiben mit ihren Blockern sichtbar, nehmen aber nicht am Ranking teil.

Auto verlangt für jeden geeigneten Kandidaten genau einen erfolgreich
abgeschlossenen Benchmark mit identischem Workloadschlüssel, Modell-SHA-256,
Benchmarkprofil-SHA-256 und Hardwareinventar-SHA-256 sowie dem
kandidatengebundenen Runtime-Hash.
Fehlt nur eine Messung, wird keine Auswahl geliefert. Primär entscheidet der
Durchsatz; bei Gleichstand folgen niedrigere P95-Latenz, geringerer Peak Working
Set und die Kandidaten-ID als stabiler Tie-Breaker.

```powershell
$selection = Get-SqlServerLabAiComputeSelection `
  -WorkloadKey sql-ai-generation `
  -ModelSha256 $modelHash `
  -BenchmarkProfileSha256 $profileHash `
  -InventorySha256 $inventoryHash `
  -Candidate $candidateSet.Candidates `
  -Benchmark $comparableReceipts
```

Eine bewusste Fixierung benötigt keine Benchmarkentscheidung, darf aber nur
einen geeigneten Kandidaten wählen:

```powershell
$selection = Get-SqlServerLabAiComputeSelection `
  -WorkloadKey sql-ai-generation `
  -ModelSha256 $modelHash `
  -BenchmarkProfileSha256 $profileHash `
  -InventorySha256 $inventoryHash `
  -Candidate $candidateSet.Candidates `
  -PinnedCandidateId rtx5080-pair
```

`Measure-SqlServerLabAiComputeCandidate` führt das zum ausgewählten Paket gehörende
`llama-bench` mit gesperrtem Netzwerkdownload (`--offline`) aus. Modell und alle
unmittelbaren Paketbinärdateien werden vor und nach dem Lauf gehasht. Derselbe
Profilhash bindet Wiederholungen, Generationslänge, Batch- und Microbatchgröße.
Jede portable Geräte-ID benötigt eine explizite, eindeutige Zuordnung zum
Runtime-Selector; mehrere Selektoren werden mit `/` als gemeinsamer Lauf an
`llama-bench` übergeben. CPU verwendet ausschließlich `none`.

```powershell
$benchmarks = foreach ($candidate in $candidateSet.Candidates | Where-Object Eligible) {
  Measure-SqlServerLabAiComputeCandidate `
    -Inventory $inventory `
    -Candidate $candidate `
    -RuntimeDirectory $runtimeDirectory `
    -ModelPath $modelPath `
    -WorkloadKey sql-ai-generation `
    -DeviceBinding $bindingsByCandidate[$candidate.CandidateId]
}
```

Die Zuordnung zwischen portabler Hardware-ID und `llama.cpp`-Selector wird noch
nicht automatisch hergeleitet. Sie muss deshalb bewusst für jeden Kandidaten
angegeben werden; fehlende, doppelte oder widersprüchliche Bindungen blockieren
vor dem Prozessstart. Erst genau ein gültiges Receipt je geeignetem Kandidaten
erlaubt die automatische Auswahl.

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

Zuerst werden die lokalen Dateien ohne Prozessstart gegen den Plan gebunden:

```powershell
$runtimeHash = (Get-FileHash C:\AI\llama-server.exe -Algorithm SHA256).Hash
$modelHash = (Get-FileHash C:\AI\embedding.gguf -Algorithm SHA256).Hash
$plan = Get-SqlServerLabAiExternalModelPlan `
  -Backend LlamaCppOpenVino -Accelerator NPU `
  -Location https://localhost:11435/v1/embeddings `
  -ExternalModelName LocalNpuEmbedding -RuntimeModel bound-model -Dimension 768 `
  -RuntimeSha256 $runtimeHash -ModelSha256 $modelHash `
  -ServerCertificateSha256 $serverCertificateHash
$plan | Test-SqlServerLabAiExternalModelArtifact `
  -RuntimePath C:\AI\llama-server.exe -ModelPath C:\AI\embedding.gguf
```

Das Receipt enthält nur Digests und Evidence-Codes. Es übernimmt keine lokalen
Pfade und bestätigt weder einen laufenden Prozess noch NPU-Nutzung.

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
     SECRET = '{"Authorization":"Bearer <lokaler API-Key>"}';

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

Der eigene Windows-Gateway kann einen bereits gestarteten OVMS-Upstream
verifizieren und zeitlich begrenzt als Loopback-HTTPS-Endpunkt bereitstellen:

```powershell
$apiKey = Read-Host 'Gateway API key' -AsSecureString
$gateway = Start-SqlServerLabOvmsHttpsGateway `
  -UpstreamLocation 'http://127.0.0.1:9000/v3/embeddings' `
  -RuntimeModel 'OpenVINO/Qwen3-Embedding-0.6B-int8-ov' `
  -Dimension 1024 -Port 19443 `
  -CertificatePath C:\certs\ovms-gateway.pem `
  -PrivateKeyPath C:\certs\ovms-gateway-key.pem `
  -TrustedRootPath C:\certs\lab-root.pem `
  -ApiKey $apiKey -LeaseSeconds 900

$plan = Get-SqlServerLabAiExternalModelPlan `
  -Backend OpenVinoModelServer -Accelerator NPU -TlsMode Gateway `
  -Location $gateway.Location -ExternalModelName OvmsNpu `
  -RuntimeModel $gateway.RuntimeModel -Dimension $gateway.Dimension `
  -ModelSha256 $modelHash -RuntimeSha256 $runtimeHash `
  -ServerCertificateSha256 $gateway.ServerCertificateSha256 `
  -GatewayBinding $gateway

$root = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
  [IO.File]::ReadAllText('C:\certs\lab-root.pem'))
$endpointReceipt = $plan | Test-SqlServerLabAiExternalModelEndpoint `
  -ApiKey $apiKey -TrustedRootCertificate $root
$sqlPlan = Get-SqlServerLabAiExternalModelSqlPlan `
  -Plan $plan -EndpointReceipt $endpointReceipt -DatabaseName AiLab
$root.Dispose()

Stop-SqlServerLabOvmsHttpsGateway -OperationId $gateway.OperationId
```

Der Worker bindet nur `127.0.0.1`, verwendet keinen Proxy oder Redirect,
rekonstruiert genau einen Embeddingrequest und entfernt seine API-Key-Datei beim
Stop, Ownerverlust oder Lease-Ende. Zertifikat und Key bleiben Eigentum des
Callers. Der Plan rechnet den Binding-Key aus Operation, Lease,
Upstream-Binding, HTTPS-Location, Modell, Dimension und Zertifikatspin erneut
nach. Fehlende, manipulierte oder abweichende Bindungen blockieren. Der
resultierende Status `NOT_PROBED` erlaubt die getrennte HTTPS-Probe, führt aber
noch keine SQL-Mutation aus und bestätigt keine Acceleratornutzung. Der interne
Ollama-Gateway aus der
Docker-Referenzabnahme ist weiterhin keine allgemeine OVMS-Gateway-API.
Auch der resultierende SQL-Plan ist nur ein zeitlich begrenzter, geheimnisfreier
Vertrag. Insbesondere ist der OVMS-v3-Pfad noch nicht nativ durch SQL Server 2025
abgenommen.

Ein bereits vom Operator gestarteter OVMS-Upstream kann vorab ohne Mutation
geprüft werden:

```powershell
Test-SqlServerLabOvmsUpstreamEndpoint `
  -Location 'http://127.0.0.1:9000/v3/embeddings' `
  -RuntimeModel 'OpenVINO/Qwen3-Embedding-0.6B-int8-ov' `
  -Dimension 1024
```

Die Prüfung akzeptiert nur eine numerische Loopback-Adresse, Klartext-HTTP,
einen nicht privilegierten Port und exakt `/v3/embeddings`. Ihr Receipt belegt
Antwortform, Modell und Dimension des Upstreams, aber weder TLS-Gateway,
Prozessbesitz noch NPU-Nutzung.

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

## Lokale llama.cpp-Installation erkennen

`Get-SqlServerLabLlamaCppRuntime -SearchRoot 'C:\Pfad\llama' -Accelerator NPU`
findet Windows- und Linux-Pakete anhand von `llama-server.exe` beziehungsweise
`llama-server` und plattformüblichen Backendbibliotheken, ohne
Hashes, Prozessstart oder Netzwerkzugriff. Explizite Suchwurzeln ersetzen die
Umgebungssuche; ohne sie werden `SQL_SERVER_LAB_LLAMA_ROOT` und der erste
Treffer für `llama-server.exe` im Prozess-PATH verwendet. Es werden höchstens
32 Wurzeln mit jeweils 256 unmittelbaren Unterverzeichnissen geprüft.
Laufwerkswurzeln werden abgewiesen, Reparse-Verzeichnisse übersprungen.
Nicht lesbare Wurzeln ergeben eine Warnung; eine leere Ausgabe ist dann kein
Beweis, dass der Host keine Installation besitzt. Eine überschrittene Grenze
bricht die Suche ab, statt einen scheinbar vollständigen Bestand zu liefern.

`INSTALLED` und `FILES_ONLY` bestätigen ausschließlich die gefundenen Dateien.
`CandidateAccelerators` ist ein Paketfilter, kein Nachweis verfügbarer Hardware.
Mehrere Backend-DLLs ergeben `Backend=Ambiguous`; es wird kein Backend still
gewählt. Die Sortierung verwendet den aus dem Verzeichnisnamen abgeleiteten
Build absteigend und anschließend den Pfad; sie ist keine Eignungsentscheidung.
`Build` ist unverifizierte Namensinformation. `ReleaseReference` verweist auf
die [offiziellen Pakete](https://github.com/ggml-org/llama.cpp/releases),
`PackageOrigin=UNVERIFIED` bestätigt ausdrücklich nicht deren Herkunft.
Die Rückgabe enthält lokale Pfade und darf nicht versioniert werden.

Für OpenVINO wird CPU, GPU oder NPU später explizit mit
`GGML_OPENVINO_DEVICE` gewählt. Ein unbekannter laufender Prozess wird weder
übernommen noch beendet. Ein Generations-GGUF ist kein bestätigtes
Embeddingmodell. Modellpfad, Pooling und Dimension müssen separat feststehen;
dieser Discovery-Vertrag startet keinen Dienst. Optionale Artifact-Evidence
bindet erst die konkret ausgewählten Dateien. Der bestehende hashgebundene
Endpointplan ist ein separater Vertrag und keine Voraussetzung der Discovery.

## Eigenen Windows-Server starten und beenden

Nach der expliziten Paketauswahl sind keine vorab bekannten Runtime- oder
Modellhashes erforderlich:

```powershell
$runtime = Start-SqlServerLabLlamaCppRuntime `
  -RuntimeDirectory 'C:\Pfad\llama' -Backend LlamaCppCuda -Accelerator GPU `
  -ModelPath 'C:\Pfad\embedding.gguf' -ModelName local-embedding `
  -Dimension 768 -Pooling mean -Port 19435 `
  -CertificatePath 'C:\Pfad\run\server.pem' `
  -PrivateKeyPath 'C:\Pfad\run\server-key.pem' `
  -TrustedRootPath 'C:\Pfad\run\ca.pem' -ApiKey $apiKey `
  -StartTimeoutSeconds 120 -LeaseSeconds 900
try {
  # In derselben Modulsitzung kann SQL den verifizierten Endpunkt nutzen,
  # nachdem seine eigene Route und CA-Vertrauensstellung geprüft wurden.
  $runtime
}
finally {
  Stop-SqlServerLabLlamaCppRuntime -OperationId $runtime.OperationId
}
```

Der API-Key ist ein SecureString aus 24 bis 256 ASCII-Buchstaben, Ziffern,
Unterstrichen oder Bindestrichen. Das Zertifikat braucht einen IP-SAN für
`127.0.0.1`. Für Docker ist zusätzlich der eigene DNS-SAN und das Vertrauen im
SQL-Container erforderlich. Die Lease umfasst die Startphase; Modulfreigabe
oder Ownerverlust beendet den Server. `CaptureArtifactEvidence` ergänzt
optional die Digests erst nach erfolgreicher Probe. Der bestehende
External-Model-Plan und seine Artifact-Prüfung bleiben davon unabhängig.

Ein Modellname allein beweist keine Kompatibilität: Ein vorhandenes
Ollama-Embeddinggemma-GGUF scheiterte unter b11104 beim Laden; ein vorhandenes
Nomic-Embedding-GGUF lief unter CUDA, scheiterte aber unter OpenVINO-NPU bei
der Berechnung. Keine dieser Abweichungen führt zu einem stillen Fallback.
[Ownership-, Probe- und Cleanupvertrag](../Architecture/LLAMA_CPP_OWNED_RUNTIME.md).
