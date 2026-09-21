# Podman-KI-Testumgebung aus der Konsole

Stand: 2026-09-21. Status: `VALIDATED_REFERENCE`.

`Invoke-SqlServerLab` bietet unter **Datenbanken und Verbindungen → SQL Server 2025 KI → Podman-KI-Testumgebung
erstellen** einen geführten Aufbau. Er erstellt nach Vorschau und Bestätigung
einen neuen SQL-Server-2025-Podman-Run mit eigener Datenvolume, verwaltetem
SA-Secret und der festen synthetischen Initial-Collection. Der Controller
verwendet ausschließlich vorhandenes lokales Ollama mit
`embeddinggemma:latest` und 768 Dimensionen. Anschließend muss die feste Frage
`backup` das Dokument `backup-policy` zuerst finden.

Der Dialog fragt Name, Ollama-Loopbackport (Standard 11434), CPU (Standard 2)
und RAM in MB (Standard 4096). SQL erhält einen freien lokalen Port. Fehlende
Podman-Bereitschaft, fehlendes Modell, Cloudidentität, falsche Capability,
Dimension, Version oder fehlender Digest verhindern die Erstellung. Der
vorhandene HostTool-Initializer wird pro neuem Prozess verwendet; keine
Podman-Machine wird automatisch gestartet. Modellinventar und Runtimebindung
werden unmittelbar vor und während der Ausführung erneut geprüft.

## Nutzung und Aufbewahrung

Bei Erfolg bleiben Run, Volume, Datenbank und Retrieval-Journal erhalten.
**Meine KI-Testumgebungen anzeigen** zeigt die dauerhaften Run- und Collection-IDs,
den Erstellungsstatus und den aktuellen lokalen Run-State auch nach einem
neuen Konsolenstart. SQL-Verbindungen werden über das bestehende Connection
Center geöffnet; der Dialog gibt keine Kennwörter aus. Die feste Abfrage kann
mit den angezeigten IDs erneut ausgeführt werden:

```powershell
Invoke-SqlServerLabAiPersistentRetrieval -RunId $runId -CollectionId $collectionId -Action Query -QueryId backup
```

Bei abweichendem Ollama-Port ist derselbe `-LocalPort` anzugeben. Die bestehende
Run-Entfernung entfernt die Umgebung ausdrücklich; die Creation-Historie ist
kein Beweis dafür, dass ein später entfernter Run noch läuft. Der Ablauf
ändert weder Golden-RAG noch andere Umgebungen. Er installiert oder lädt kein
Modell herunter, startet Ollama nicht neu und nimmt keine eigenen Dokumente,
Cloudziele oder SQL-Texte entgegen. Er richtet kein SQL External Model und
keinen HTTPS-Gateway ein. Der separate Docker-HTTPS-Nachweis gilt hier nicht.

## Besitz und Fehlergrenzen

Vor `New-SqlServerLab` steht ein schema-validiertes atomar geschriebenes
Operationsjournal unter `StateRoot/ai-environments/<operationId>/setup.json`.
Der private Worker trägt dieselbe Operation in den neuen Run ein. Ein
verlorenes New-Ergebnis wird über diese Operation und den Run-State gefunden,
niemals über einen frei gewählten Namen. Runtime-Scope, Run-, Scope-,
Container-, Volume- und Instanzbindung folgen den bestehenden Transfer- und
Retrieval-Verträgen. Replay einer begonnenen Operation ist gesperrt. Ein
bestätigtes `READY` ist vor automatischer Fehlerbereinigung geschützt.

Die Erstellung läuft in einem unsichtbaren Kindprozess mit 1200 Sekunden
Gesamtbudget. Nach Fehler oder Abbruch wird sein Ende bestätigt; anschließend
haben Collection-Remove und Whole-Run-Remove getrennte Budgets von 120 und
600 Sekunden. Ein fehlgeschlagenes oder zeitlich abgebrochenes
Collection-Remove verhindert die autorisierte Entfernung des ganzen eigenen
Runs nicht. Unbestätigtes Prozessende, Runtimewechsel, geänderte Ownership oder
unbestätigte Restfreiheit führen zu `RECOVERY_REQUIRED`. PrimaryReason und
CleanupStatus bleiben getrennt. Ein Fehler mit bestätigter vollständiger
Bereinigung bleibt `FAILED`, er wird nicht als erfolgreiche Erstellung gemeldet.
Hat New seinen Run bereits selbst vollständig bereinigt, wird der eindeutig
operationseigene terminale Run nur nach passendem abgeschlossenen Cleanupplan,
Provider-/Runtimebindung und aktueller Container-/Volumerestfreiheit anerkannt.
Dieser Nachweis löst keine erneute Runtime-Mutation aus.

Die privaten Prozesslogs und Identitätsdaten bleiben im nur für den aktuellen
Benutzer zugänglichen Operationsverzeichnis. Die Konsole erhält nur geschlossene
Statuswerte und die nutzbaren Run-/Collection-IDs. State und Logs werden auch
bei Fehlern nicht gelöscht. Nach hartem Abbruch des Elternprozesses gibt es
keinen automatischen Neustart oder Hintergrund-Recoverydienst; die gespeicherte
Operation und der bestehende besitzgebundene Run-Recoverypfad sind zu prüfen.

## Validierung

`Tests/Static/Invoke-AiPodmanSetupChecks.ps1` führt den echten privaten
Orchestrator mit synthetischen Provider-/SQL-Grenzen aus: Preflight, Vorschau,
Abbruch, Reihenfolge, Persistenz, verlorenes New-Ergebnis, Drift, konkurrierender
Replay, getrennte Cleanupfehler und Menü-/Connection-Center-Integration.
`Invoke-AiPodmanSetupProcessChecks.ps1` startet echte begrenzte Testprozesse
für Timeout, Abbruch, Teilabbruch, Streamdrain und private Ausgabe.

Die native Podman-Referenz auf `9d8d313a` bestand am 2026-09-21 mit sechs
Assertions und Exitcode 0: eigene SQL-2025-Erstellung, persistierte
768-dimensionale Collection, auffindbare IDs, Query vor/nach SQLrestart,
gleiche Runtimebindung und unverändertes Hostmodellinventar. Das Cleanup wurde
unabhängig bestätigt: exakt eine eigene Operation, Run `REMOVED`, passende
Runtime und null verbleibende eigene Container oder Volumes. Dies belegt den
festen synthetischen Referenzfall; es ist keine Freigabe anderer Provider,
Modelle, Cloud- oder SQL-External-Model-Pfade.

Der eigene temporäre Test benötigt bereits bereites Podman und das vorhandene Modell:

```powershell
./Tests/Integration/Invoke-AiPodmanSetupAcceptance.ps1 -LocalPort 11434
```

Der Harness erstellt ausschließlich einen eigenen temporären StateRoot und
Lab_Data-Bereich, serialisiert den bestehenden Runtime-Smoke-Mutex und prüft
Collection-Persistenz, Query vor/nach öffentlichem SQLrestart, gleiche
Runtimebindung und unverändertes Hostmodellinventar. Nur sein eigener
erfolgreicher Fixture-Run wird abschließend ausdrücklich verworfen. Bei
unsicherem Prozessende bleibt State erhalten, statt konkurrierendes Cleanup
zu beginnen. Der Harness akzeptiert keinen bestehenden Nutzer-Run als Ziel.
Er gibt ausschließlich eine geschlossene PASS/FAILED-/Cleanup-Zeile aus.
Primär- und Cleanupfehler bleiben zur Diagnose im privaten Testverzeichnis.

Die Capability ist Podman-spezifisch. Änderungen am gemeinsamen CI-Selektor
wählen weiterhin die volle Pflichtmatrix; diese breitere Infrastrukturprüfung
ist kein Docker- oder Hyper-V-Nachweis für die neue Erstellung.

Gekoppelte Grundlagen: [Persistentes Retrieval](AI_PERSISTENT_RETRIEVAL.md),
[lokale Validierungsstrategie](../Quality/LOCAL_VALIDATION_STRATEGY.md).
