# Isolierte Hyper-V-Abnahme für lokales RAG und Diagnose

Stand: 2026-09-20. Status: `IMPLEMENTED_NATIVE_PENDING`. Die neue Abnahme
verwendet ausschließlich einen eigenen SQL-Server-2025-Run aus einem explizit
ausgewählten, bereits registrierten `SQL_PREPARED_SEALED`-Developer-Artefakt.
Sie ersetzt weder den bisherigen `PARTIAL`-Nachweis noch das Golden Dataset v1.
Es gibt keinen Download, Image-Bootstrap oder Zugriff auf reservierte Test-VMs.

## Modellvertrag

RAG verwendet `embeddinggemma:latest` und `qwen2.5-coder:7b`; der Diagnose-Agent
verwendet ausschließlich dieses lokale Qwen-Modell. Der Katalogschlüssel lautet
`ollama-qwen25-coder-7b-local`. Die [Ollama-Modellseite](https://ollama.com/library/qwen2.5-coder:7b)
und die [offizielle Qwen-Modellkarte](https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct)
belegen Modell und Apache-2.0-Lizenz. Ollama 0.11.10 ist die gewählte
Unterstützungsuntergrenze dieses Repositorys. Der tatsächliche Manifestdigest
wird live gebunden; es wird kein allgemeiner Hostdigest versioniert.

Der Agent prüft Version, Capability, exakte Modellidentität und fehlende
Remoteidentity vor dem SQL-Login sowie vor und nach der Generierung. Sein
`ExecutionKey` bindet den Plan und `HostGenerationBinding`. Für diesen expliziten
Modellschlüssel gelten 180 Sekunden, 256 Ausgabetokens und genau ein Versuch.
Vorhandene Modellvoreinstellungen bleiben erhalten. Diagnoseinhalte verlassen
die lokale Lane nicht. Modelle werden weder heruntergeladen noch entfernt oder
entladen; der Hostdienst wird nicht neu gestartet. Inferenz kann das bereits
vorhandene Modell regulär in den Arbeitsspeicher laden.

`CREATE LOGIN` und `GRANT` sind getrennte SQL-Aufrufe. Scheitert die Vergabe
nach bestätigtem CREATE, entfernt `finally` die eigene zufällige Identität und
disposed ihr Secret. Ein unbestätigtes CREATE bleibt `RECOVERY_REQUIRED`; eine
Namenskollision autorisiert kein DROP. Das Journal enthält keine Inhalte.

## Vorprüfung und Ausführung

```powershell
.\Tests\Integration\Invoke-AiHyperVOwnRunAcceptance.ps1 `
    -ArtifactId $explicitPreparedArtifactId -StateRoot $registeredStateRoot -PreflightOnly
```

Die Vorprüfung liest Artefaktmetadaten mit `SkipIntegrityCheck`, prüft SHA256
selbst ohne Integrity-Cache-Schreibzugriff, ReadOnly, SQL-Developer-Lizenz,
Windows-Evaluationsrestlaufzeit und registrierten Lab_Data-Speicher. Reparse-
Pfade werden abgewiesen. Beide Hostmodelle werden vor jeder VM-Erstellung
geprüft. Ohne `PreflightOnly` benötigt der vorhandene Workflow erhöhte Rechte.

`runtime-smoke-hyperv.yml` bietet den manuellen Modus
`ai-rag-own-run-acceptance`, den verpflichtenden expliziten `image_artifact_id` und
optional `ai_state_root`. `ai_preflight_only` ist standardmäßig wahr. Derselbe
registrierte StateRoot muss im erhöhten Runner erreichbar sein; es wird kein
Artefaktkatalog kopiert. Der Modus ist nur für `workflow_dispatch` aus dem
eigenen Repository freigegeben und kann auf dem geprüften PR-Branch laufen.
Er wird nicht automatisch in den allgemeinen PR-Lifecycle aufgenommen.

Globale Runtime- und eigene Hyper-V-Mutexe umschließen Vorprüfung und Mutation.
Der neue Run bindet Operation, Run, Scope, primäre Instanz, VMId und Artefakt.
Tatsächliche VM-Laufwerke und der Differencing-Parent werden vor RAG und
Restart gelesen und mit dieser Bindung abgeglichen. Ein gleicher VM-Name
ersetzt keine VMId. Der Bootzeitnachweis verwendet PowerShell Direct mit VMId.
RUNNING/VM-Status sind Vorbedingungen; erst nachfolgende SQL-Aufrufe belegen
SQL-Erreichbarkeit.

RAG und Agent laufen vor und nach eigenem VM-Neustart, insgesamt höchstens vier
lokale Generierungsrequests ohne Retry. Die synthetische Retrieval-Top-ID wird
exakt geprüft; eine nichtleere Antwort allein ist keine Qualitätsgarantie.
Der Agent muss beide erlaubten Werkzeuge ausführen und alle temporären Logins
entfernen. Cleanup prüft Runstatus, exakte VM-Abwesenheit, eigene Childdisks und
eigene aktive IPAM-Leases. Unklare Bindung oder Cleanup bleibt Recovery, kein
PASS. Der Parent muss anschließend weiterhin unverändert und ReadOnly sein.

## Getrennte Linux-Abnahme und Evidence

```powershell
.\Tests\Integration\Invoke-AiRagExistingOllamaAcceptance.ps1 `
    -Provider podman -LocalGeneration -IncludeDiagnostic -GenerationTimeoutSeconds 230
```

Dieser zusätzliche Parametersatz benötigt keine Cloudsecrets. Docker und
Podman müssen getrennt geprüft werden: lokale Generierung und Diagnose vor
und nach SQLrestart, Login-Cleanup und eigene Container-/Volume-Abwesenheit.
Der bestehende Cloud-Parametersatz bleibt unverändert. PASS wird erst nach
Cleanup ausgegeben.

Die Offline-Fixtures prüfen Modell-/Remoteidentitydrift, Credential-Lebensdauer,
GRANT-Teilfehler und unbestätigtes CREATE, VMId-/Instanz-/Parent-/Attachmentdrift,
geschützte Runs sowie eigene und fremde IPAM-Leases. Native Nachweise für diese
neue Modellpaarung sind für Docker und Podman am 2026-09-20 getrennt bestanden: RAG und Diagnose vor/nach SQLrestart, keine Diagnose-Logins sowie vollständiges eigenes Container-/Volume-Cleanup. Der Hyper-V-Nachweis steht noch aus. Persistentes Retrieval, Re-Embedding und
SQL-seitiges EXTERNAL MODEL/TLS-Gateway sind weiterhin separate offene Slices.
