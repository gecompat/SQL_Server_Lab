# Eigener llama.cpp-Embeddingserver für SQL Server 2025

## Vertrag

`Start-SqlServerLabLlamaCppRuntime` startet unter Windows oder Linux ein ausgewähltes
llama.cpp-Paket mit einem ausdrücklich angegebenen Embedding-GGUF. Der bisherige
explizite CUDA-/OpenVINO-Modus bleibt erhalten. Alternativ übernimmt der Start
eine `SqlServerLab.AiComputeSelection/1.0` aus Auto oder Pinned und bindet damit
CPU, CUDA, OpenVINO, ROCm, Vulkan oder SYCL einschließlich mehrerer GPUs.
Da dieser Lifecycle ausschließlich Embeddings bereitstellt, akzeptiert er nur
eine Auswahl mit `WorkloadKey=sql-ai-embedding`; der Benchmarkproducer erzeugt
diese Receipts mit `BenchmarkMode=Embedding`.
Modellalias, Dimension, Pooling, Port, Zertifikat, privater Key und API-Key sind
in beiden Modi Pflichtangaben. Die reine
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

Das Runtimeverzeichnis wird unmittelbar revalidiert. Im expliziten Altmodus
blockieren mehrdeutige Backend-DLLs weiterhin. Im Auswahlmodus muss der
Paketdigest dagegen exakt dem ausgewählten Runtimehash entsprechen; das gewählte
Backend muss im Paket enthalten sein. Inventar- und Modellhash, Gerätearten,
Herstellergrenzen und Runtime-Selektoren werden ebenfalls erneut geprüft.
Fehlende Dateien, falsches GGUF-Magic, unpassende Zertifikat-/Key-Paare und
belegte Ports blockieren. Es gibt keine Übernahme fremder Prozesse.
OpenVINO erhält im Kindprozess ausdrücklich `GGML_OPENVINO_DEVICE=CPU|GPU|NPU`.
Für NPU werden keine OpenVINO-Cacheverzeichnisse gesetzt, weil Upstream diese
Gerätekombination nicht unterstützt. CPU und GPU erhalten weiterhin ausschließlich
operationsgebundene Cachepfade.
Der explizite CUDA-GPU-Modus verwendet `CUDA0`; CUDA-CPU verwendet `--device none`
und null GPU-Layer. Der Auswahlmodus leitet die Selektoren standardmäßig aus
der aktuellen `--list-devices`-Ausgabe ab oder akzeptiert eine vollständige
explizite Bindung. Mehrere Geräte werden kommagetrennt mit `split-mode=layer`
übergeben. Automatische Fit-Anpassung ist aus, modellbezogene geerbte
`LLAMA*`-/`GGML*`-/CUDA-/OpenVINO-Overrides werden im Kindprozess entfernt.

Vor Erfolg müssen Listener-PID und eigener Prozess übereinstimmen. Die
HTTPS-Probe prüft Zertifikatskette, IP-SAN und Leaf-Pin, genau einen Modellalias
unter `/v1/models`, denselben Alias in der Embeddingantwort sowie genau einen
endlichen Vektor der verlangten Dimension. Redirects und Proxys sind aus.
Ein eigener fester synthetischer Text wird verwendet; die Rückgabe enthält
weder Text, Vektor, Secret noch lokale Dateipfade.

Zusätzlich werden ausschließlich die Logs dieses gestarteten Prozesses
geprüft: vollständiger Layer-Offload und ein Modell-/Compute-Puffer je
ausgewähltem CUDA-, ROCm-, Vulkan- oder SYCL-Gerät,
explizite OpenVINO-Gerätewahl mit vollständigem Offload oder CPU-Compute ohne
GPU-Modell-/Compute-Puffer für CUDA-CPU. Erkannter Fallback blockiert. Diese
Evidence belegt Runtimekonfiguration und erfolgreiche Berechnung gemeinsam;
sie ist keine unabhängige Hardwaretelemetrie und kein Performancebenchmark.
Unbekannte künftige Logformate können deshalb geschlossen scheitern. Im
Auswahlmodus werden Runtimepaket und Modell nach erfolgreicher Probe erneut
gehasht; Drift beendet die eigene Operation.
Ein vom eigenen OpenVINO-Prozess geloggter Graph-/Computefehler bei einer
fehlgeschlagenen Embeddingantwort wird als `LLAMA_ACCELERATOR_COMPUTE_FAILED`
von einer sonst ungültigen HTTP-Antwort getrennt. Das ist Fehlerklassifikation,
kein positiver Gerätenachweis.

## Ownership, Fristen und Cleanup

Vor Start entstehen eine neue lokale Operation und ein restriktives Verzeichnis
im Benutzer-Temp. Die aktuelle Identität besitzt den Verzeichniszugriff;
API-Key, Request und Logs bleiben dort. Windows verwendet eine geschützte DACL,
Linux Modus `0700` für das Verzeichnis und `0600` für den Key. Der Key steht
ausschließlich in einer Datei, niemals in Prozessargumenten. Caller-Zertifikat und -Key werden nicht
kopiert, überschrieben oder gelöscht.

Unter Windows tritt ein isolierter Worker vor dem Serverstart einem eigenen Job
Object mit `KILL_ON_JOB_CLOSE` bei. Unter Linux startet er den Server ausschließlich
über das vorhandene util-linux-Programm `setpriv --pdeathsig KILL`; fehlt dieses,
blockiert der Start vor dem Serverprozess. Der Steuerkanal ist in beiden Fällen
eine anonyme stdin-Pipe. Ownerverlust oder Modulfreigabe schließen sie;
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

## Geführter Stop vorhandener eigener Sitzungen

CLI: **Host-Dienste und Modelle → Eigene llama.cpp-Sitzung auswählen und stoppen**.
GUI: derselbe Bereich, **Eigene llama.cpp-Sitzung stoppen**. Die Sicht enthält nur
Workerobjekte der aktuell gehaltenen Modulsitzung, einschließlich
`CLEANUP_PENDING` nach Workerende. Vorschau und Abbruch stoppen nichts. Eine
fünf Minuten gültige, serverseitig gehaltene Auswahl bindet Operation, exakt
gehaltenes Sitzung-/Workerobjekt und Port. Zielersatz, Ablauf oder geänderte
Schutz-/Verbraucherreferenzen blockieren vor Stop. Die Bestätigung führt genau
den bestehenden Worker-/Key-Cleanup aus; Logs und Callerdateien bleiben erhalten.
Ein verbrauchtes Receipt ist nicht wiederverwendbar. Bei Cleanupfehlern die
weiterhin eigene Operation frisch auswählen oder das bestehende Stop-Cmdlet
für deren Recovery verwenden. Es gibt keinen automatischen Neustart.

`Invoke-SqlServerLabWorkflowAction` bietet `GetLlamaSessions`,
`PlanLlamaSessionStop -LlamaSessionOperationId` und
`StopLlamaSession -LlamaSessionPlanId -ConfirmLlamaSessionStop`. CLI und
HTTP `/api/llama-sessions` verwenden dieselbe serverseitige Authority. Die
HTTP-Grenze nimmt keine PID, Pfade oder vollständigen Planobjekte entgegen.

Verbraucher-Coverage bleibt ausdrücklich `UNKNOWN`. Registrierte
Shared-Gateway-Pläne mit gleichem numerischem Loopback-Upstream-Port liefern
nur deklarierte Verbraucher, keine Live-SQL-Abnahme. Ihr Ausfall und mögliche
unbekannte Verbraucherfolgen werden vor Bestätigung angezeigt. Eine deklarierte
Referenz auf einen in `TestUmgebung.registry.json` geschützten Run blockiert.
Eine konfigurierte, unlesbare Schutzauthority blockiert ebenfalls. Registrierung
und geführter Stop teilen deren bestehende Gruppen-Sperre; unmittelbar vor dem
Stop werden Referenzen erneut gelesen. Eine leere deklarierte Liste bestätigt
keine Verbraucherfreiheit. Das ändert den bisherigen automatischen,
ownershipgebundenen Cleanup nicht.

Gatewaypublikation und geführter Stop teilen zusätzlich eine kanonische
StateRoot-Lifecyclesperre. Feste Reihenfolge: zuerst StateRoot, danach beim
Registrar dessen Gateway-Sperre beziehungsweise beim Stop die bestehende
Testgruppen-Sperre. Relative-, Case- und Separatoraliaspfade teilen die
Sperre; Reparsepfade werden abgewiesen. Der Registrar wartet höchstens 30 Sekunden auf die StateRoot-Sperre, damit identische parallele Registrierungen weiterhin idempotent bleiben; Vorschau und Stop melden eine belegte Sperre unmittelbar. Damit kann eine neue bekannte
Gatewaypublikation nicht nach der letzten Observation in das Stopintervall
eintreten. Nicht-Leaf-, Reparse- und unlesbare konfigurierte Registrypfade
blockieren; tatsächlich fehlende Registry und noch nicht provisionierte
Einträge ohne RunId bleiben reguläre Zustände.

Für die GUI zuerst den bestehenden Start-Aufruf in **derselben PowerShell**
ausführen und danach `./Tools/Start-SqlServerLabUi.ps1` starten. Der UI-Host
verwendet den bereits geladenen exakten Modulpfad ohne Force-Reload weiter;
ein anderes Modul desselben Namens blockiert. Die bisherigen erforderlichen
Startparameter gelten vollständig. Ein Start aus anderer PowerShell oder über
separat importierende Hintergrundjobs erscheint hier nicht. Eine leere GUI-Sicht
nennt diese Abhilfe. Die Native-Abnahme des geführten Browser-Starts, Fremdprozesse, Windows-Dienste, Restart,
Konfiguration und Modell-Lifecycle bleiben offen; das ist keine allgemeine
Ownershipbeschränkung für künftige bewusste manuelle Hostaktionen.

`Invoke-LlamaCppSessionGuidanceChecks.ps1` prüft Core, echten UI-Modulimport,
HTTP-Grenze und CLI mit synthetischen Runtimegrenzen. Die echte Browserfixture
prüft Vorschau, Bestätigung, Cancel, leere Sicht und verspätete Antworten.
Der opt-in Case `GuidedStop` des Ownership-Acceptance-Harness bestand am
2026-09-30 unter Windows mit Exitcode 0: echte Workflow-Vorschau, Cancel,
abgelaufene Vorschau, Apply und Replayabwehr. Eigener Worker und wartendes Kind
endeten; die eigene Keydatei war abwesend. Das Nachbarkind blieb während des
Stops aktiv und wurde danach separat operationseigen bereinigt; Testroot-Cleanup
war bestätigt. Der Nachweis nutzt ausschließlich synthetische native Prozesse
und eine isolierte Schutzregistry, keine SQL-, Modell-, Compute- oder
Providerprobe. Verbrauchercoverage bleibt UNKNOWN; die UI-/CLI-Handler und der
exakte UI-Modulsitzungserhalt sind separat synthetisch geprüft.
## Nachweise und Grenzen

`Invoke-LlamaCppOwnedRuntimeChecks.ps1` prüft Accelerator-Negative, fremde
Operationen, Linux-Listenerzuordnung, restriktive Rechte und Hashfreiheit.
`Invoke-LlamaCppOwnershipAcceptance.ps1` führt
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
Ein entsprechender echter Linux-Ownerverlust-/Lease-/Worker-Kill-Nachweis sowie
ein nativer ROCm-Endpunktlauf sind noch offen. Positive NPU-, OpenVINO-GPU-/CPU-, CUDA-CPU-, Mehr-GPU-, ROCm-, Vulkan-, SYCL-,
Podman- und Hyper-V-Nachweise bleiben separat. Die neue Auswahlbindung ist
statisch belegt und noch keine native Hardware-Evidence. Discovery und Start
installieren keine Modelle.

Am 2026-09-22 bestand der begrenzte CUDA-/Nomic-Referenzpfad: eigener Server,
HTTPS-Pin, Modellalias, 768 endliche Werte, vollständiger GPU-Layer-Offload,
Auth-Abweisung sowie echte SQL-2025-Docker-Embeddings vor/nach SQLrestart.
Prozess, API-Key, eigene Testzertifikate, SQL-Container und Volume wurden
bereinigt. Zusätzlich bestanden falscher Pin, Dimensionsabweichung mit
Cleanup sowie synthetischer Ownerverlust, Lease-Ende und Worker-Kill.
Dies ist keine positive OpenVINO-NPU-Evidence und kein Backendbenchmark.

## Reine Vorschau für einen eigenen llama.cpp-Start

`Get-SqlServerLabLlamaCppStartPlan` liefert `SqlServerLab.LlamaCppStartPlan/1.0`
für SQL-Server-2025-Embeddings. Der Core nimmt ausschließlich explizite
`RuntimeDirectory`, `Backend`, `Accelerator`, `ModelPath`, `Dimension`, `Pooling`
und `Port` sowie die bestehenden numerischen Start-/Lease-/Kontextgrenzen an.
Keine Auswahl über ComputeSelection, Inventar oder Gerätebindung und keine
Modellalias-, Zertifikats-, API-Key- oder Private-Key-Eingaben. Der vorhandene
Start, sein WhatIf und der sitzungsgebundene Stop bleiben unverändert.

Eine explizite lokale Runtimewurzel besitzt höchstens 16 direkte Unterordner
und 256 Dateien je betrachtetem Verzeichnis. Root, Vorfahren, direkte
Kandidaten und Dateien dürfen keine Reparse-Pfade sein. Der bestehende
Files-only-Reader erkennt die exakt gewählte Installation; benachbarte
Kandidaten werden nicht übernommen. Unbekannte oder mehrdeutige Backends,
Backenddrift und CUDA-NPU blockieren. Der CPU-Installer ist kein impliziter
CUDA-/OpenVINO-Kompatibilitätsnachweis. Es werden keine Binaries gestartet.

Die reguläre Modelldatei wird nur über Metadaten und genau vier GGUF-Magic-Bytes
beobachtet. Zwei Metadatenbeobachtungen erkennen sichtbaren Drift, sind aber
kein CAS-, Byteintegritäts-, ABA- oder späterer Ausführungsnachweis; ein Austausch
mit gleichen Metadaten ist nicht ausgeschlossen. Dateimengen begrenzen die
Ausgabe, nicht die Laufzeit blockierender Dateisystemaufrufe. Kein vollständiges
Modellhashing, kein rekursiver Suchlauf und keine Umgebungs-/PATH-Discovery.

Die sanitisierte Ausgabe bleibt stets `PLAN_ONLY/BLOCKED`, mit `Actions=[]`,
`ExecutionSupported=false` und `MutationAllowed=false`. Pfade, Dateinamen,
freie Callertexte, Inhaltsdigests und ausführbare PlanKeys fehlen. GGUF-Magic
belegt weder Embeddingeignung, Dimension noch Pooling. Geräte, Port, TLS,
Keymatching, SAN/Trust und SQL bleiben getrennt `NOT_CHECKED`. Kein Listener,
Prozess, HTTP-, SQL-, Secret-, Defaults- oder Registryzugriff und keine Persistenz.
Ein bewusster späterer Start benötigt alle ursprünglichen Eingaben und seine
eigene frische Runtime-/TLS-/SQL-Abnahme.

Die CLI bietet unter „Alle öffentlichen Befehle“ → „llama.cpp: geführte
Startvorschau“ eine reine Eingabeführung. Genau zehn bestehende explizite
Parameter bleiben im RAM. Erst „Vorschau anzeigen“ liest die lokalen Dateien
über denselben Public-Core. Back/Esc an Auswahl und Vorschau ruft ihn nicht auf.
Maskierte Pfadeingaben verwenden Esc, im Fallback Ctrl+C statt 0. Der Dialog
zeigt keine Pfade, freien Fehlertexte oder zusätzlichen DTO-Felder. Er verwirft
ungültige/mutierende Ergebnisse und bleibt PLAN_ONLY/BLOCKED. Kein Startknopf,
ComputeSelection, Secretzugriff, globale Discovery oder Speicherung. Der geführte Browser-Start ist separat implementiert; seine Native-Abnahme bleibt offen.

### Reine llama.cpp-Dateivorschau im Browser

Unter „Host-Dienste und Modelle“ → „llama.cpp: reine Startvorschau“ werden
Runtime-Verzeichnis, GGUF-Datei, Backend, Beschleuniger und die sechs
Modell-/Budgetwerte ausdrücklich im Arbeitsspeicher erfasst. Erst
„Dateivorschau lesen“ ruft den unveränderten öffentlichen Dateiplan auf.
Öffnen, Bearbeiten, Zurück und Escape lesen keine Dateien und erzeugen keinen
Job. Abbruch verwirft die Eingaben und ignoriert verspätete Antworten.

Die Vorschau bleibt PLAN_ONLY/BLOCKED mit leeren Actions. Geräte, Port, TLS,
Modellkompatibilität und SQL bleiben NOT_CHECKED. Pfade werden maskiert erfasst
und weder im Ergebnis noch in Fehlern gespiegelt; es gibt keine Persistenz oder
Ausführungsfreigabe. Clearing ist keine sichere Speicherlöschung. Die zwei
Dateimetadatenbeobachtungen bieten keinen CAS-, Integritäts- oder späteren
Startnachweis. Kein Startknopf, ComputeSelection, Secret-, Zertifikats-,
Sitzungs- oder Inventarzugriff. Der bestehende Start und eigene Sitzungsstop
bleiben getrennte Verträge; der geführte Browser-Start ist separat implementiert; seine Native-Abnahme bleibt offen.

## Geführter eigener llama.cpp-Start in der CLI

Unter „Alle öffentlichen Befehle“ → „llama.cpp: eigene Sitzung starten“ erfasst
die CLI fünfzehn explizite Eingaben einschließlich optionalem öffentlichen
CA-PEM. Pfade und API-Key werden maskiert, der API-Key als SecureString erfasst.
Vor der Bestätigung bleiben Eingaben im RAM; Dateien, TLS, Port und Runtime
werden nicht gelesen oder geprüft. Scalargrenzen sind Eingabeprüfung, keine
Modell-/Gerätebereitschaft. WhatIf des vorhandenen öffentlichen Starts liest
keine Dateien und startet nichts. Die separate Dateivorschau bleibt PLAN_ONLY.

Erst die bewusste Bestätigung ruft den unveränderten öffentlichen Start in
derselben Modulsitzung auf; dessen natürliche Confirm-Abfrage bleibt aktiv.
Der bestehende Core prüft Runtime, GGUF, TLS und Loopback-Embeddings und erzeugt
ausschließlich seine eigene Worker-/Key-/Lease-Operation. Die Anzeige enthält
keine Pfade, Modellaliase, Zertifikatspins oder Secrets. Der dialogeigene
SecureString wird anschließend verworfen; die laufende eigene Sitzung bleibt
in diesem Modulhost. Ein unerwartetes Ergebnis nach Start ist unbestätigt und
kann eine aktive Sitzung bedeuten. Kein AutoStop, Retry oder behaupteter Cleanup;
RECOVERY_REQUIRED bleibt sichtbar. Den Modulhost erhalten und bestehende eigene
Sitzungsführung bewusst separat verwenden. SQL-Funktionsabnahme bleibt
NOT_CHECKED. Der geführte Browser-Start ist separat implementiert; seine Native-Abnahme bleibt offen.

Die neue Führung ist synthetisch geprüft; reale Start-/Modell-/TLS-/Compute-
und Cleanup-Abnahme dieses Dialogs ist nicht ausgeführt. Bestehende native
Referenznachweise ersetzen diese Abnahme nicht.

## Geführter eigener llama.cpp-Start im Browser

Unter „Host-Dienste und Modelle“ → „llama.cpp: eigene Sitzung starten“ erfasst
der Dialog fünfzehn explizite Eingaben einschließlich optionalem CA-PEM und
transientem API-Key. Öffnen, Bearbeiten und Abbruch vor Versand lesen keine
Dateien und rufen keinen Start auf. Erst die bewusste Wirkungsbestätigung
sendet START; eine ausdrücklich gewählte WhatIf-Aktion braucht diese Bestätigung
nicht und ruft denselben öffentlichen Start mit WhatIf ohne Bereitschaftsprüfung auf.
Beide Aufrufe erzeugen wegen dessen Pflichtparameter einen frischen dialogeigenen
SecureString und entsorgen ihn anschließend. Der HTTP-String und Browser-RAM
sind nicht garantiert sicher löschbar; keine Jobs, Logs, URL- oder Storageablage
für die Eingaben. Gemeinsame 65536-Byte-/32768-Zeichenlimits können Kombinationen
maximaler Einzelwerte abweisen; Pfade sind zusätzlich auf 4096 Zeichen begrenzt.

Der dedizierte synchrone POST /api/llama-start verlangt exakte IPv4-Loopback-
Listener-/Request-/Originbindung und nutzt das unveränderte vorhandene Modul.
Kein Force-Reload oder Hintergrundjob. Natürliche ShouldProcess-Semantik bleibt:
Low/Medium/unbekannte effektive ConfirmPreference blockieren vor Public, High/None
werden nicht überschrieben. WhatIf/No-op ist kein Erfolg oder Readinessnachweis.
Das Startbudget von 1–600 Sekunden begrenzt nur Core-Bereitschaftspolls nach
Workerstart, nicht gesamten HTTP-Aufruf, Datei-/TLS-I/O oder Cleanup. Der
UI-Listener kann synchron blockieren; Modulhost für die eigene Sitzung behalten.

Abbruch nach Versand betrifft ausschließlich die Anzeige. Eine verlorene oder
unerwartete Antwort kann eine aktive eigene Sitzung bedeuten. Feste Ergebnis-
und Recoveryanzeigen enthalten keine Pfade, Modellaliase, Zertifikatspins oder
Secrets; nur bestätigte eigene UUID/Port-/Sitzungsbindung wird projiziert.
Kein automatischer Stop, Retry, Ownershipadoption oder Cleanup-Erfolgsversprechen.
Bestehende eigene Sitzungsführung bleibt separat; SQL bleibt NOT_CHECKED.
Die Browserführung ist synthetisch geprüft; neue reale Start-/Modell-/TLS-/
Compute-/Cleanup-Abnahme und ausgewählte Provider-Gates sind NOT_EXECUTED.
