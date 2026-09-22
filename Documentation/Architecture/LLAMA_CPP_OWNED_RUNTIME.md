# Eigener llama.cpp-Embeddingserver für SQL Server 2025

## Vertrag

`Start-SqlServerLabLlamaCppRuntime` startet unter Windows ein explizit
gewähltes CUDA- oder OpenVINO-Paket mit einem ausdrücklich angegebenen
Embedding-GGUF. Backend, Accelerator, Modellalias, Dimension, Pooling, Port,
Zertifikat, privater Key und API-Key sind Pflichtangaben. Die reine
[Discovery](../User/SQL_AI_LOCAL_ACCELERATION.md) erfordert keine Hashes.
Auch Start verlangt keinen Hash. `CaptureArtifactEvidence` hasht optional die
konkret gewählten Runtime-/Modelldateien nach erfolgreicher Probe; während
Start und Hashing verhindern lesende Dateisperren eine Änderung dieser Dateien.
Der Exe-Digest attestiert nicht sämtliche Backend-DLLs des Pakets.

Der Dienst bindet ausschließlich an `127.0.0.1`; die Probe verwendet diese
Adresse ohne DNS-Auflösung. Das Zertifikat benötigt den passenden IP-SAN.
Ein Caller kann für einen getrennten Docker-Nachweis zusätzlich den SAN
`host.docker.internal` vorsehen. Die SQL-seitige Route und CA-Vertrauensstellung
müssen getrennt belegt werden. Der Start ändert weder Hosttrust, Firewall,
Hosts-Datei, Dienste noch globale Umgebungsvariablen und lädt nichts herunter.

## Auswahl und Verifikation

Das Runtimeverzeichnis wird unmittelbar revalidiert. Mehrdeutige Backend-DLLs,
CUDA-NPU, fehlende Dateien, falsches GGUF-Magic, unpassende Zertifikat-/Key-
Paare und belegte Ports blockieren. Es gibt keine Übernahme fremder Prozesse.
OpenVINO erhält im Kindprozess ausdrücklich `GGML_OPENVINO_DEVICE=CPU|GPU|NPU`.
Für NPU werden keine OpenVINO-Cacheverzeichnisse gesetzt, weil Upstream diese
Gerätekombination nicht unterstützt. CPU und GPU erhalten weiterhin ausschließlich
operationsgebundene Cachepfade.
CUDA-GPU verwendet `CUDA0`; CUDA-CPU verwendet `--device none` und null
GPU-Layer. Automatische Fit-Anpassung ist aus, modellbezogene geerbte
`LLAMA*`-/`GGML*`-/CUDA-/OpenVINO-Overrides werden im Kindprozess entfernt.

Vor Erfolg müssen Listener-PID und eigener Prozess übereinstimmen. Die
HTTPS-Probe prüft Zertifikatskette, IP-SAN und Leaf-Pin, genau einen Modellalias
unter `/v1/models`, denselben Alias in der Embeddingantwort sowie genau einen
endlichen Vektor der verlangten Dimension. Redirects und Proxys sind aus.
Ein eigener fester synthetischer Text wird verwendet; die Rückgabe enthält
weder Text, Vektor, Secret noch lokale Dateipfade.

Zusätzlich werden ausschließlich die Logs dieses gestarteten Prozesses
geprüft: vollständiger Layer-Offload und Compute-Puffer für CUDA-GPU,
explizite OpenVINO-Gerätewahl mit vollständigem Offload oder CPU-Compute ohne
GPU-Modell-/Compute-Puffer für CUDA-CPU. Erkannter Fallback blockiert. Diese
Evidence belegt Runtimekonfiguration und erfolgreiche Berechnung gemeinsam;
sie ist keine unabhängige Hardwaretelemetrie und kein Performancebenchmark.
Unbekannte künftige Logformate können deshalb geschlossen scheitern.
Ein vom eigenen OpenVINO-Prozess geloggter Graph-/Computefehler bei einer
fehlgeschlagenen Embeddingantwort wird als `LLAMA_ACCELERATOR_COMPUTE_FAILED`
von einer sonst ungültigen HTTP-Antwort getrennt. Das ist Fehlerklassifikation,
kein positiver Gerätenachweis.

## Ownership, Fristen und Cleanup

Vor Start entstehen eine neue lokale Operation und ein restriktives Verzeichnis
im Benutzer-Temp. Die aktuelle Identität besitzt den Verzeichniszugriff;
API-Key, Request und Logs bleiben dort. Der Key steht ausschließlich in einer
Datei, niemals in Prozessargumenten. Caller-Zertifikat und -Key werden nicht
kopiert, überschrieben oder gelöscht.

Ein isolierter Worker tritt vor dem Serverstart einem eigenen Windows Job
Object mit `KILL_ON_JOB_CLOSE` bei. Kinder erben diese Bindung. Der Steuerkanal
ist eine anonyme stdin-Pipe. Ownerverlust oder Modulfreigabe schließen sie;
Lease-Ende, Startfrist oder überschrittenes Logbudget beenden die eigene
Prozessgruppe. Beide Logs sind auf jeweils 4 MiB begrenzt. Die maximale Lease beträgt eine Stunde und
umfasst die Startphase. Es gibt weder unbegrenzte Retries noch Persistenz als
Windows-Dienst oder automatischen Neustart.

`Stop-SqlServerLabLlamaCppRuntime -OperationId $runtime.OperationId` verwendet
nur das in derselben Modulsitzung gehaltene Workerobjekt. Unbekannte IDs
blockieren. Normaler Stop wartet auf den Worker; nötigenfalls wird nur dieser
Worker beendet, wodurch sein Job die Kinder beendet. PID und Startzeit dienen
anschließend ausschließlich der lesenden Abwesenheitsprüfung. Die eigene
API-Key-Datei wird gelöscht. `CLEANUP_SUCCEEDED` betrifft Prozess und Key;
Request, Status und Logs bleiben lokal zur Diagnose, Callerdateien bleiben
unverändert. Unbestätigtes Ende meldet `LLAMA_RECOVERY_REQUIRED` getrennt vom
ursprünglichen Fehler. Direkter externer Worker-Kill kann die Key-Datei bis zum
Stop durch den Owner hinterlassen; sie bleibt restriktiv geschützt.

Ein laufender Server ist sitzungsgebunden. Für weitere Arbeit dieselbe
Modulsitzung behalten; ein erneuter Import mit `-Force` beendet deren Ownership.
Nach Rechnerneustart existiert kein eigener Dienst, der wiederaufgenommen wird.

## Nachweise und Grenzen

`Invoke-LlamaCppOwnedRuntimeChecks.ps1` prüft Accelerator-Negative, fremde
Operationen und Hashfreiheit. `Invoke-LlamaCppOwnershipAcceptance.ps1` führt
unter Windows echte synthetische Kindprozesse für Ownerverlust, Lease-Ende, Worker-Kill und das harte Loglimit aus; ein
weiterer Fall bestätigt Cleanup-Wiederholung nach vorübergehender Dateisperre.
Alle Fälle bestätigen eigenes Testroot-Cleanup.
`Invoke-LlamaCppSqlAcceptance.ps1` ist eine separate opt-in Docker-Abnahme mit
vorhandenem CUDA-Paket und Nomic-kompatiblem Embedding-GGUF, eigener Test-CA,
SQL-2025-Run, External Model, endlichen `VECTOR(768)`, SQLrestart und Cleanup.

Ein vorhandenes Ollama-GGUF ist nicht automatisch llama.cpp-kompatibel.
Die lokale Embeddinggemma-Variante scheiterte mit Build b11104 an einer
Tensoranzahlabweichung. Nomic konnte unter CUDA Embeddings liefern;
die OpenVINO-NPU-Kombination scheiterte bei der Graphberechnung. Diese Fälle
werden nicht durch automatische Modell- oder Gerätewechsel umgangen.
Am 2026-09-23 reproduzierten zwei vorhandene kleine BERT-Embeddingmodelle auf
demselben NPU-Pfad die fehlende `inp_pos`-Graphanforderung; beide eigenen
Prozesse und API-Key-Dateien wurden bereinigt. Weitere gleichartige BERT-
Varianten wurden nach der identischen Signatur nicht blind wiederholt.
Positive NPU-, OpenVINO-GPU-/CPU-, CUDA-CPU-, Podman- und Hyper-V-Nachweise
bleiben separat. Die Discovery und der Start installieren keine Modelle.

Am 2026-09-22 bestand der begrenzte CUDA-/Nomic-Referenzpfad: eigener Server,
HTTPS-Pin, Modellalias, 768 endliche Werte, vollständiger GPU-Layer-Offload,
Auth-Abweisung sowie echte SQL-2025-Docker-Embeddings vor/nach SQLrestart.
Prozess, API-Key, eigene Testzertifikate, SQL-Container und Volume wurden
bereinigt. Zusätzlich bestanden falscher Pin, Dimensionsabweichung mit
Cleanup sowie synthetischer Ownerverlust, Lease-Ende und Worker-Kill.
Dies ist keine positive OpenVINO-NPU-Evidence und kein Backendbenchmark.
