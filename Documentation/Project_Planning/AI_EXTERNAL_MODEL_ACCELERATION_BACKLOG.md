# Beschleunigte lokale KI-Endpunkte für SQL External Models – Backlog

## Status und Priorität

`IMPLEMENTED_PARTIAL / USER_PRIORITY_P0`. Dieser Arbeitsstrom hat Vorrang vor allgemeinen
Routineerweiterungen. Er erweitert den vorhandenen, nativ belegten
[Docker-Referenzslice](../Architecture/AI_SQL_HTTPS_BRIDGE.md) von
`CREATE EXTERNAL MODEL` um auswählbare lokale Inferenzruntimes und echte
CPU-/GPU-/NPU-Evidence. Planung oder ein erfolgreicher Prozessstart gelten
nicht als Beschleunigungsnachweis.

Der vorhandene Referenzslice bleibt gültig: SQL Server 2025 ruft ein lokales
Ollama-Modell über einen kurzlebigen HTTPS-Gateway auf, erzeugt die Embeddings
selbst und prüft TLS-Negative, Ranking, SQL-Neustart und Cleanup. Offen sind
allgemeine Backendwahl, Installation, weitere Gerätebindungen, Podman, Hyper-V und die
unten beschriebenen Hardwarepfade.

## Zielbild

SQL Server bleibt Besitzer von External Model, Credential, Vektoren, Suche und
Abnahme. Ein lokaler Inferenzdienst stellt eine klar gebundene OpenAI- oder
Ollama-kompatible Embedding-API bereit. Der Plan wählt die Runtime explizit;
ein stiller Wechsel zwischen NPU, GPU, CPU, lokal und Cloud ist unzulässig.

Bevorzugte Reihenfolge:

1. `llama.cpp` mit OpenVINO und NPU auf Windows als erster Referenzpfad;
2. direkte SQL-Anbindung über `API_FORMAT='OpenAI'` und `/v1/embeddings`;
3. vorhandenen scopegebundenen HTTPS-Gateway verwenden, wenn ein Backend nur
   HTTP anbietet oder direkte TLS-Bindung nicht sicher erreichbar ist;
4. OpenVINO Model Server als alternative Intel-Runtime;
5. AMD Ryzen AI NPU und ROCm-iGPU unter Linux getrennt bewerten;
6. Intel-NPU, Intel-iGPU und NVIDIA RTX 5080 auf dem großen Windows-System
   gegeneinander messen;
7. weitere portable Pfade, darunter Snapdragon, als getrennte Hardwarelane.

## Arbeitspakete

| ID | Priorität | Ziel | Status und erforderlicher Nachweis |
|---|---:|---|---|
| `AIX-001` | P0 | Allgemeiner lokaler External-Model-Endpunktvertrag | `IMPLEMENTED_PARTIAL`: Plan bindet Runtime, Modell-/Dateidigest, Dimension, Inputprofil, Accelerator, Endpoint und TLS. Getrennte read-only Prüfungen bestätigen lokale Runtime-/Modelldateien sowie Zertifikatspin, OpenAI-Antwortform, endliche Werte und Dimension. Geräteattestation, SQL-Mutation und Cleanup bleiben getrennte Nachweise. |
| `AIX-002` | P0 | `llama.cpp` OpenVINO auf Intel NPU unter Windows 11 | `IMPLEMENTED_PARTIAL`: Discovery und expliziter OpenVINO-Start sind vorhanden. Nomic scheiterte unter b11104 an der Graphberechnung; zwei kleine BERT-Modelle reproduzierten die fehlende `inp_pos`-Graphanforderung. Der Start klassifiziert belegte OpenVINO-Computefehler jetzt eindeutig und setzt keine nicht unterstützten NPU-Cachepfade. Ein positives kompatibles Embeddingmodell, SQL, Ranking und Restart bleiben offen. |
| `AIX-003` | P0 | HTTPS ohne dauerhaften Hosttrust oder breite Listenerfreigabe | `IMPLEMENTED_PARTIAL`: Die Hostprobe prüft Leaf-Pin, SAN und Systemtrust oder eine ausschließlich im Prozess verwendete Custom Root ohne Proxy, Redirect oder Truststoreänderung. Direktes `llama-server`-TLS mit eigener SQL-CA, CUDA/Nomic und SQLrestart ist unter Docker am 2026-09-22 nativ belegt; weitere Backendpaare bleiben separat. |
| `AIX-004` | P0 | Intel Core Ultra 7 165U, Windows 11 | `USER_EVIDENCE`: OpenVINO-Build von `llama.cpp` ist installiert und NPU-Nutzung funktioniert. Discovery und Start benötigen keinen Digest; die optionale Datei-Evidence folgt erst auf die konkrete Auswahl. Endpoint-, Geräte- und SQL-Evidence dieser Kombination bleiben separat. |
| `AIX-005` | P0 | Intel Core Ultra 9 275HX plus Intel-Grafik und RTX 5080 Laptop GPU | `IMPLEMENTED_PARTIAL`: CUDA/Nomic bestand die eigene HTTPS-/SQL-2025-Docker-Referenz einschließlich SQLrestart und Cleanup. NPU, OpenVINO-/SYCL-iGPU, Vulkan und vergleichbare Performance-Messungen bleiben separat. |
| `AIX-006` | P0 | GMKtec EVO-X2, Ryzen AI Max+ 395, Linux | `RESEARCHED`: Ryzen AI Software unterstützt Linux-NPU-Flows; ROCm führt `gfx1151` offiziell. NPU-Serviceadapter und `llama.cpp`-ROCm sind getrennte Lanes. ROCm ist der zuerst ausführbare Serverkandidat, NPU bleibt das bevorzugte Ziel. |
| `AIX-007` | P1 | OpenVINO Model Server | `IMPLEMENTED_PARTIAL`: Die read-only Probe bindet einen vorhandenen OVMS-v3-Upstream an numerischen Loopback, exakten Modellnamen, Antwortform und Dimension. Der getrennte Windows-TLS-Gateway-Lifecycle besitzt Ownerkanal, Lease, Auth und Request-/Response-Rekonstruktion. Der External-Model-Plan rechnet das Gateway-Receipt kanonisch nach; die synthetische End-to-End-Abnahme bestätigt Planbindung, HTTPS-Probe und einen altersgebundenen geheimnisfreien SQL-2025-Mutations-/Cleanupplan. SQL-Mutation, SQLrestart und Acceleratorattestation bleiben offen. |
| `AIX-008` | P1 | Backendvergleich und Auswahl | `BACKLOG`: gleiche Modellfamilie, Dimension, Inputs und SQL-Assertions; Warmup, Latenz, Durchsatz, Arbeitsspeicher, Energie soweit messbar sowie tatsächliches Zielgerät werden protokolliert. |
| `AIX-009` | P2 | Snapdragon Windows ARM64 | `RESEARCHED`: Upstream liefert CPU- und Adreno-OpenCL-Artefakte. Hexagon-NPU erfordert derzeit zusätzliche SDK-/Treiber- und Signaturschritte und bleibt wegen des Hosteingriffs eine eigene opt-in Lane. |

## HTTPS- und Netzwerkentscheidung

Die bevorzugte Reihenfolge minimiert Hoständerungen:

1. Backend bindet ausschließlich Loopback, liefert selbst TLS und hält den
   Schlüssel in einem operationseigenen Verzeichnis. `llama-server` besitzt
   dafür `--ssl-key-file`, `--ssl-cert-file` und `--api-key-file`.
2. Bei HTTP-only-Backends terminiert der bestehende kurzlebige Host-Gateway
   TLS und leitet ausschließlich an einen festen Loopback-Upstream weiter.
3. Ein Proxy-Sidecar ist sinnvoll, wenn Backend und SQL-Run über ein isoliertes
   Containernetz erreichbar sind. OpenVINO Model Server empfiehlt selbst einen
   Reverse Proxy, da seine Endpunkte keine Transportverschlüsselung anbieten.
4. Eine Hosts-Datei ordnet nur Namen Adressen zu. Sie macht einen ausschließlich
   an Host-Loopback gebundenen Dienst aus einem Container nicht erreichbar und
   ist daher allein keine Lösung. Docker `host.docker.internal` und Podman
   `host.containers.internal` benötigen jeweils einen realen Erreichbarkeits-
   und TLS-Nachweis.
5. Hyper-V benötigt einen eigenen, auf internen Switch, Quell-VM und Port
   begrenzten Pfad. Eine Firewallregel darf nur operationgebunden entstehen und
   muss im Cleanup nachweislich verschwinden.

Die CA wird nicht in den globalen Hosttrust importiert. Für Linux-SQL liegt ihr
öffentlicher Anteil ausschließlich im eigenen SQL-Volume; der private Schlüssel
bleibt beim Gateway. Direkte TLS-Runtimes verwenden einen SAN, den SQL über den
gewählten Runtimepfad tatsächlich aufruft. HTTP, falsche CA, falscher SAN,
fehlende Authentisierung und ein fremdes Modell müssen fail-closed scheitern.

## Plattformreihenfolge

### Intel Core Ultra 7 165U – Windows 11

Der Prozessor besitzt laut Intel Intel AI Boost mit 11 INT8-TOPS und führt
OpenVINO als unterstütztes NPU-Framework. Der erste Projekt-Slice übernimmt den
bereits funktionierenden `llama.cpp`-OpenVINO-Aufbau, ohne ihn neu zu installieren:

1. Binär-, Runtime-, Modell- und Treiberidentität read-only erfassen;
2. NPU explizit mit `GGML_OPENVINO_DEVICE=NPU` wählen;
3. Embeddingmodus, modellgerechtes Pooling, kurze Kontextgrenze, TLS und
   API-Key-Datei aktivieren;
4. `/health` und `/v1/embeddings` lokal prüfen;
5. SQL `CREATE EXTERNAL MODEL ... API_FORMAT='OpenAI'` und
   `AI_GENERATE_EMBEDDINGS` mit fester deutscher Ranking-Fixture ausführen;
6. Prozess-/SQL-Neustart, falsches Gerät und vollständiges Cleanup prüfen.

### GMKtec EVO-X2 – Ryzen AI Max+ 395, Linux

Zwei getrennte Pfade sind nötig:

- **NPU:** Ryzen AI Software für Linux, XRT/`amdxdna`, `xrt-smi examine` und
  ein NPU-kompiliertes Encoder-/Embeddingmodell. Da die Herstelleranleitung
  keinen direkt SQL-kompatiblen HTTPS-Embeddingserver festlegt, ist ein kleiner
  allowlistgebundener OpenAI-Adapter mit eigenem TLS-Gateway erforderlich.
- **iGPU:** ROCm auf `gfx1151` und `llama-server` mit HIP. Dies ist der
  praktischere erste Servernachweis und darf nicht als NPU-Nachweis bezeichnet
  werden. Vulkan bleibt ein messbarer Fallbackkandidat, nie ein stiller Fallback.

### Intel Core Ultra 9 275HX, Intel-Grafik und RTX 5080 Laptop GPU

Für dasselbe GGUF-/Embedding-Fixture werden getrennt geprüft:

- OpenVINO `NPU` als stromsparender Zielpfad;
- OpenVINO oder SYCL auf der Intel-iGPU;
- CUDA auf RTX 5080; Vulkan als explizite Vergleichslane;
- CPU nur als Baseline und Recoverydiagnose.

Eine schnellere RTX-Lane darf die vom Nutzer gewünschte NPU-Eignungsprüfung
nicht verdrängen. Bekannte upstream RTX-5080-/CUDA-Regressionsmeldungen werden
vor dem Festschreiben einer Buildversion erneut geprüft.

## Abnahmevertrag

Jede unterstützte Kombination benötigt:

1. versions- und digestgebundene Runtime sowie ein vertrauenswürdiges Modell;
2. explizite Gerätewahl und runtimeeigene Evidence, dass dieses Gerät den
   Request ausgeführt hat;
3. HTTPS, Authentisierung, CA-/SAN-Negative und kein Secret in Argumenten,
   State, Logs oder Receipts;
4. SQL-2025-External-Model, endliche Vektoren in exakter Dimension und die
   erwartete semantische Rangfolge;
5. Runtime- und SQL-Neustart ohne ungebundenen Modellwechsel;
6. getrennte Docker-, Podman- oder Hyper-V-Evidence nur dort, wo die Plattform
   tatsächlich betroffen ist;
7. operationseigenes Cleanup sowie sichtbares `RECOVERY_REQUIRED`, wenn es
   nicht bestätigt werden kann.

## Primärquellen

- Microsoft: [CREATE EXTERNAL MODEL](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-external-model-transact-sql?view=sql-server-ver17)
- llama.cpp: [OpenVINO backend](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENVINO.md)
- llama.cpp: [Server, OpenAI-Embedding-API und TLS](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- llama.cpp: [Release-Artefakte](https://github.com/ggml-org/llama.cpp/releases)
- OpenVINO Model Server: [Embedding-Demo](https://github.com/openvinotoolkit/model_server/blob/main/demos/embeddings/README.md)
- OpenVINO Model Server: [Security](https://docs.openvino.ai/2026/model-server/ovms_docs_security.html)
- Intel: [Core Ultra 7 165U](https://www.intel.com/content/www/us/en/products/sku/237329/intel-core-ultra-7-processor-165u-12m-cache-up-to-4-90-ghz/specifications.html)
- Intel: [Core Ultra 9 275HX](https://www.intel.com/content/www/us/en/products/sku/242293/intel-core-ultra-9-processor-275hx-36m-cache-up-to-5-40-ghz/specifications.html)
- AMD: [Ryzen AI Software unter Linux](https://ryzenai.docs.amd.com/en/latest/linux.html)
- AMD: [ROCm-Linux-Supportmatrix für Ryzen](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityryz/native_linux/native_linux_compatibility.html)
- llama.cpp: [Snapdragon unter Windows](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/snapdragon/windows.md)

Der konkrete [Windows-Ownershipvertrag](../Architecture/LLAMA_CPP_OWNED_RUNTIME.md) bindet Start/Stop, Lease, Endpointprobe und optionales Artifact-Hashing.
