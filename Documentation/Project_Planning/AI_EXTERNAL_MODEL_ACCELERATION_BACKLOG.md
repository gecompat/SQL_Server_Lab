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
allgemeine Hardwareinventarisierung, Benchmarkausführung, weitere Gerätebindungen, Podman, Hyper-V und die
unten beschriebenen Hardwarepfade.

## Zielbild

SQL Server bleibt Besitzer von External Model, Credential, Vektoren, Suche und
Abnahme. Ein lokaler Inferenzdienst stellt eine klar gebundene OpenAI- oder
Ollama-kompatible Embedding-API bereit. Auto wählt standardmäßig die schnellste
geeignete CPU-/NPU-/Einzel-GPU-/Mehr-GPU- oder gemischte Kombination nur aus
vollständiger vergleichbarer Benchmark-Evidence. Eine explizite Fixierung
überschreibt Auto. Ein stiller Wechsel zwischen NPU, GPU, CPU, lokal und Cloud
ist unzulässig.

Umsetzungsreihenfolge:

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
| `AIX-001` | P0 | Allgemeiner lokaler External-Model-Endpunktvertrag | `IMPLEMENTED_PARTIAL`: Plan bindet Runtime, Modell-/Dateidigest, Dimension, Inputprofil, Accelerator, Endpoint und TLS. Getrennte read-only Prüfungen bestätigen lokale Runtime-/Modelldateien, Zertifikatspin, OpenAI-Antwortform, endliche Werte und Dimension sowie SQL-2025-Zielscope, Datenbank-GUID, Master Key, Rechte und freie Objektnamen. Geräteattestation, SQL-Mutation und Cleanup bleiben getrennte Nachweise. |
| `AIX-002` | P0 | `llama.cpp` OpenVINO auf Intel NPU unter Windows 11 | `IMPLEMENTED_PARTIAL`: Discovery und expliziter OpenVINO-Start sind vorhanden. Nomic scheiterte unter b11104 an der Graphberechnung; zwei kleine BERT-Modelle reproduzierten die fehlende `inp_pos`-Graphanforderung. Der Start klassifiziert belegte OpenVINO-Computefehler jetzt eindeutig und setzt keine nicht unterstützten NPU-Cachepfade. Ein positives kompatibles Embeddingmodell, SQL, Ranking und Restart bleiben offen. |
| `AIX-003` | P0 | HTTPS ohne dauerhaften Hosttrust oder breite Listenerfreigabe | `IMPLEMENTED_PARTIAL`: Die Hostprobe prüft Leaf-Pin, SAN und Systemtrust oder eine ausschließlich im Prozess verwendete Custom Root ohne Proxy, Redirect oder Truststoreänderung. Direktes `llama-server`-TLS mit eigener SQL-CA, CUDA/Nomic und SQLrestart ist unter Docker am 2026-09-22 nativ belegt; weitere Backendpaare bleiben separat. |
| `AIX-004` | P0 | Intel Core Ultra 7 165U, Windows 11 | `USER_EVIDENCE`: OpenVINO-Build von `llama.cpp` ist installiert und NPU-Nutzung funktioniert. Discovery und Start benötigen keinen Digest; die optionale Datei-Evidence folgt erst auf die konkrete Auswahl. Endpoint-, Geräte- und SQL-Evidence dieser Kombination bleiben separat. |
| `AIX-005` | P0 | Intel Core Ultra 9 275HX plus Intel-Grafik und RTX 5080 Laptop GPU | `IMPLEMENTED_PARTIAL`: CUDA/Nomic bestand die eigene HTTPS-/SQL-2025-Docker-Referenz einschließlich SQLrestart und Cleanup. NPU, OpenVINO-/SYCL-iGPU, Vulkan und vergleichbare Performance-Messungen bleiben separat. |
| `AIX-006` | P0 | GMKtec EVO-X2, Ryzen AI Max+ 395, Linux | `RESEARCHED`: Ryzen AI Software unterstützt Linux-NPU-Flows; ROCm führt `gfx1151` offiziell. NPU-Serviceadapter und `llama.cpp`-ROCm sind getrennte Lanes. ROCm ist der zuerst ausführbare Serverkandidat, NPU bleibt ein eigenständiger Vergleichskandidat. |
| `AIX-007` | P1 | OpenVINO Model Server | `IMPLEMENTED_PARTIAL`: Die read-only Probe bindet einen vorhandenen OVMS-v3-Upstream an numerischen Loopback, exakten Modellnamen, Antwortform und Dimension. Der getrennte Windows-TLS-Gateway-Lifecycle besitzt Ownerkanal, Lease, Auth und Request-/Response-Rekonstruktion. Der External-Model-Plan rechnet das Gateway-Receipt kanonisch nach; die synthetische End-to-End-Abnahme bestätigt Planbindung, HTTPS-Probe und einen altersgebundenen geheimnisfreien SQL-2025-Mutations-/Cleanupplan. Der read-only SQL-Preflight ist statisch belegt; SQL-Mutation, SQLrestart und Acceleratorattestation bleiben offen. |
| `AIX-008` | P1 | Backendvergleich und Auswahl | `IMPLEMENTED_PARTIAL`: Windows-/Linux-Hostinventar mit expliziter CPU-/GPU-/NPU-Coverage, inhaltsgebundene llama.cpp-Pakete, herstellergefilterte CPU-/CUDA-/ROCm-/Vulkan-/SYCL-/OpenVINO-Lanes und vollständige Kandidatenbildung sind implementiert. `Measure-SqlServerLabAiComputeCandidate` führt `llama-bench` offline aus, bindet GGUF, Paket, Profil, Inventar und Kandidat und liefert Durchsatz, P95-Latenz sowie Peak Working Set. Runtime-Geräteselektoren werden standardmäßig aus der aktuellen eindeutigen `--list-devices`-Ausgabe abgeleitet; ein explizites Binding bleibt möglich und mehrdeutige Teilmengen fallen geschlossen aus. Der Auswahlkern verwendet Auto als Default und verlangt vollständige vergleichbare Evidence; Pinned fixiert ohne Benchmarkentscheidung. Der eigene Windows-llama.cpp-Start konsumiert diese Auswahl hashgebunden einschließlich Mehr-GPU. Energieattestation, native Matrix und Linux-Consumerintegration bleiben offen. |
| `AIX-009` | P2 | Snapdragon Windows ARM64 | `RESEARCHED`: Upstream liefert CPU- und Adreno-OpenCL-Artefakte. Hexagon-NPU erfordert derzeit zusätzliche SDK-/Treiber- und Signaturschritte und bleibt wegen des Hosteingriffs eine eigene opt-in Lane. |

## Gemeinsamer Lab-Gateway, Zertifikate und Wiederherstellung (AIX-003)

Anforderung vom 2026-09-23, Status `BACKLOG`: Der dauerhafte gemeinsame
Gateway-Lebenszyklus einschließlich paralleler KI-Labs, Backup, Restore und
Zertifikatswechsel ist noch nicht implementiert oder nativ nachgewiesen.
Die vorhandenen HTTPS-Referenzen bleiben begrenzte Nachweise der Transportstrecke.

### Geltungsbereich und Ist-Stand

Gateway, CA, Serverzertifikat, private Schlüssel und Modellanbindung gehören
vollständig zum SQL_Server_Lab. Ein externer Infrastrukturbetreiber ist weder
Voraussetzung noch Bestandteil des Zielbilds. Ein KI-Lab bezeichnet hier einen
einzelnen SQL-Run mit seinen Datenbanken und Collections; der gemeinsame
Gateway gehört zur übergeordneten Lab-Verwaltung und nicht zu einem einzelnen Run.

Der [Ollama-SQL-HTTPS-Referenzslice](../Architecture/AI_SQL_HTTPS_BRIDGE.md)
erzeugt einen temporären Gateway und eine kurzlebige CA pro Testoperation und
entfernt diese beim Cleanup. Der vorhandene OVMS-Gateway akzeptiert
wiederverwendbare caller-eigene Zertifikatsdateien, ist aber sitzungsgebunden
und auf höchstens eine Stunde begrenzt. Beides erfüllt den gemeinsamen
dauerhaften Lebenszyklus noch nicht. Der
[llama.cpp-Start](../Architecture/LLAMA_CPP_OWNED_RUNTIME.md) ist ebenfalls
ein eigener begrenzter Runtimevertrag und kein gemeinsamer Gatewaydienst.

Das [persistente Retrieval](../Architecture/AI_PERSISTENT_RETRIEVAL.md) ruft
lokales Ollama derzeit vom Controller über Loopback-HTTP auf und speichert
Dokumente und Vektoren über die SQL-Verbindung. Es benötigt keinen HTTPS-Gateway.
Dieser Backlog betrifft direkte SQL-Modellaufrufe und die gemeinsame
HTTPS-Anbindung; er behauptet keine bereits vorhandene Gatewaybindung der
persistenten Collection-API oder eine allgemeine Cloud-API-Unterstützung.

### Gemeinsamer Lebenszyklus und parallele Nutzung

- Ein stabil identifizierter Gateway mit dauerhaft registrierter Konfiguration
  und definiertem Endpunkt dient mehreren KI-Labs gleichzeitig. Unterstützte
  Ollama-/OpenAI-kompatible Upstreams werden explizit gebunden; der Gateway ist
  kein beliebiger offener Proxy und wechselt Modelle oder Cloudziele nicht still.
- Gleichzeitige Einrichtung verwendet eine serialisierte, idempotente
  Registrierung und verhindert doppelte Gateways, Portkollisionen sowie
  widersprüchliche Zertifikatserzeugung. Verbraucher werden über stabile
  Run-/Instanzbindungen erfasst, nicht allein über Anzeigenamen.
- Stop, Remove, Fehlercleanup oder Neuaufbau eines einzelnen KI-Labs darf den
  gemeinsamen Gateway, dessen Zertifikate und andere Verbraucher nicht verändern
  oder entfernen. Das gilt auch nach Entfernen des letzten einzelnen Runs:
  gemeinsame Komponenten bleiben bis zu ihrer eigenen expliziten Entfernung erhalten.
- Gateway und Konfiguration überleben das Ende der erstellenden
  PowerShell-Sitzung. Host-/Gateway-Neustart benötigt einen dokumentierten
  Wiederanlauf mit Status-, Ownership- und Endpointprüfung. Ein Ausfall wird
  sichtbar gemeldet; bestehende Daten bleiben erhalten. Ein einzelner gemeinsamer
  Gateway verspricht keine unterbrechungsfreie Verfügbarkeit während seines Austauschs.
- Zugangsdaten und SQL-Credentials werden eindeutig je KI-Lab verwaltet.
  Widerruf oder Wiederherstellung eines Verbrauchers beeinträchtigt andere nicht.
  Limits, parallele Requests und Fehler eines Upstreams benötigen getrennte Tests.

### Zertifikate ohne globale Host-Vertrauensänderung

- CA, gültiges Serverzertifikat und private Schlüssel liegen geschützt in einem
  gemeinsamen lokalen Lab-Speicher außerhalb einzelner Run- und temporärer
  Testverzeichnisse. Sie werden beim normalen Neuaufbau eines KI-Labs weiterverwendet.
- Keine automatische Installation einer Lab-CA in den globalen Host-Rootstore
  oder dauerhafte Host-Zertifikatsbindungen. Dateien allein erweitern das
  Systemvertrauen nicht. Host-Proben verwenden eine prozessgebundene Custom Root;
  nur die öffentliche CA wird gezielt in die jeweilige SQL-Laufzeit eingebracht.
- Private Schlüssel und Zugangsdaten bleiben geschützt im Lab; keine Übergabe
  privater CA-/Serverschlüssel an SQL-Verbraucher und keine Aufnahme in Git,
  Diagnosebundles, ungeschützte Exporte, Logs oder Prozessargumente.
- Ablaufprüfung und bewusste Rotation sind eigene Vorgänge. Abgelaufene oder
  kompromittierte Zertifikate werden nicht allein zur Wiederverwendung behalten.
  Neue SANs, CA, Zertifikat-Pins und Zugangsdaten werden vollständig gebunden geprüft;
  es gibt keinen TLS-Bypass und keinen automatischen HTTP-Downgrade.
- Vollständige Entfernung der gemeinsamen Komponenten bereinigt nur eindeutig
  zugeordnete Dateien, Listener und gegebenenfalls Lab-Netzregeln. Aktive
  Verbraucher blockieren eine unkoordinierte Entfernung; fremde Hostzertifikate,
  Schlüssel und Trusteinträge bleiben unverändert.

### Backup, Restore und neuer Gateway

Zwei gleichwertig notwendige Wiederherstellungsfälle sind vorzusehen:

| Fall | Erforderlicher Zielvertrag |
|---|---|
| Wiederherstellung des bisherigen Gateways | Geschütztes Backup der gemeinsamen Konfiguration, CA, gültigen Zertifikate, privaten Schlüssel und notwendigen Secret-/Identitätsbindungen; Restore prüft Integrität, Zugriffsschutz, Gültigkeit und Endpointbindung vor Nutzung. |
| Vollständig neuer Gateway | Neue CA, neues Serverzertifikat, neue Schlüssel und Zugangsdaten sowie gegebenenfalls neue Adresse oder Port sind zulässig. Bestehende und aus Backup wiederhergestellte KI-Labs lassen sich kontrolliert daran anbinden; der alte private Schlüssel ist hierfür keine Voraussetzung. |

Ein SQL-Datenbankbackup allein sichert weder den gemeinsamen Gateway noch den
CA-Vertrauensbestand der SQL-Laufzeit oder sämtliche lokalen Run-/Collection-
Receipts. Der Wiederherstellungsvertrag muss SQL-Daten, Lab-Metadaten und
gemeinsame Gatewaydaten unterscheiden. Er stellt gültige neue Ownershipbindungen
her, statt alte Container-IDs oder lokale Journale ungeprüft zu übernehmen.
Verschlüsselte Datenbank-Credentials beziehungsweise Masterkey-Abhängigkeiten
werden geprüft und bei Bedarf kontrolliert wieder zugänglich gemacht oder neu
eingerichtet. Benötigte Secrets werden außerhalb ungeschützter Backups behandelt.

Die Umbindung aktualisiert gezielt SQL-CA-Vertrauen, Endpointadresse,
Credential-/External-Model-Konfiguration und Zertifikat-Pins. Alte, vom Backup
übernommene Trust- oder Endpoint-Receipts gelten nicht als frische Live-Evidence.
Vorschau, Journal, begrenzte Schritte und Recovery erhalten bei Teilfehlern
Daten und nachvollziehbaren Zustand; fremde Ressourcen werden nicht adoptiert.

Ein reiner Gateway-/Zertifikatswechsel verändert keine gespeicherten Dokumente
oder Vektoren und löst kein Re-Embedding aus. Modellidentität, Dimension und
Eingabeprofil müssen weiterhin zum Bestand passen. Eine Modellabweichung
blockiert die Nutzung und benötigt den getrennten Modellmigrationsvertrag.

### Erforderliche Abnahme, noch nicht ausgeführt

1. Zwei eigene KI-Labs A und B richten konkurrierend denselben Gateway ein und
   fragen parallel ab: genau ein gemeinsamer Gateway, konsistente Identität,
   keine Port-/Zertifikatskollision oder Vermischung von Credentials und Ergebnissen.
2. A wird entfernt und neu aufgebaut; B bleibt währenddessen abfragbar.
   A verwendet anschließend denselben Gateway, dieselbe CA und dasselbe noch
   gültige Serverzertifikat. Gemeinsame Schlüsseldateien bleiben unverändert.
3. Ende der erzeugenden Sitzung sowie Host-/Gateway-Neustart mit Wiederanlauf:
   Konfiguration und Zertifikatsidentität bleiben erhalten; beide Labs funktionieren
   nach bestätigter Readiness ohne Neuerzeugung ihrer Dokumentvektoren.
4. Geschütztes Backup und Restore des bisherigen Gateways sowie eines KI-Labs:
   TLS, Credentials, neue Runtime-/Ownershipbindung und erwartete Rankings bestehen.
5. Vollständig neuer Gateway mit neuer CA, Zertifikat und Credentials, zusätzlich
   mit geänderter Adresse/Port: das bestehende B und das aus Backup wiederhergestellte
   A werden kontrolliert umgebunden. SQL-Restart, gleiche Dokument-/Vektorhashes,
   erwartete Rankings und keine Dokument-Re-Embeddingrequests sind nachzuweisen.
6. WrongCA, WrongSAN, abgelaufenes Zertifikat, alter Pin, falsche Credentials,
   Modell-/Dimensionsdrift und unterbrochene Umbindung scheitern nachvollziehbar;
   Wiederaufnahme oder Rücknahme erhält Daten und funktioniert ohne Trust-Bypass.
7. Host-Truststore und fremde Zertifikate sind vor/nach Einrichtung, Rotation,
   Restore und vollständigem Cleanup unverändert. Eigenes Cleanup ist nachgewiesen;
   fehlendes Cleanup oder ungeklärte Ownership bleibt sichtbarer Recoverybedarf.

Docker, Podman und Hyper-V benötigen für SQL-Erreichbarkeit, CA-Vertrauen,
Neustart und Restore jeweils eigene Nachweise; Erfolg unter Docker überträgt
sich nicht auf die anderen Provider. Deterministische Offlineprüfungen gehen
den isolierten nativen Mehr-Lab-Abnahmen voraus.

## HTTPS- und Netzwerkentscheidung

Die folgenden kurzlebigen Varianten beschreiben vorhandene Referenzpfade.
Für den dauerhaften Mehr-Lab-Betrieb gilt der noch offene gemeinsame
Lebenszyklus aus AIX-003 oben; ein temporärer Gateway pro SQL-Run erfüllt ihn nicht.

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

Eine schnellere RTX-Lane gewinnt Auto nur nach vollständiger vergleichbarer
Evidence; sie entfernt die NPU-Lane nicht aus Inventar und Benchmarkmatrix.
Eine gewünschte NPU-Ausführung wird mit Pinned explizit festgelegt. Bekannte
upstream RTX-5080-/CUDA-Regressionsmeldungen werden vor dem Festschreiben einer
Buildversion erneut geprüft.

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
