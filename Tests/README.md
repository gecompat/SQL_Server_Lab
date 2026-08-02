# Tests/ – lokale und Remote-Validierung

## Verzeichnisse

| Verzeichnis | Inhalt |
|---|---|
| `Static/` | Import-, Export-, JSON-, Schema-, Metadaten-, Link-, Menü- und Dokumentationskonsistenz |
| `Integration/` | mutierende Lifecycle-, Provider-, Versions- und Parallelitäts-Smoke-Tests |

## Statische Prüfungen

```powershell
.\Tests\Static\Invoke-AllChecks.ps1
.\Tests\Static\Invoke-ManifestBuilderChecks.ps1
.\Tests\Static\Invoke-DocumentationChecks.ps1
.\Tests\Static\Invoke-ReadinessContractChecks.ps1
.\Tests\Static\Invoke-MixedProviderLifecycleChecks.ps1
.\Tests\Static\Invoke-ArtifactResolverChecks.ps1
.\Tests\Static\Invoke-SampleHandlerChecks.ps1
.\Tests\Static\Invoke-ProjectAdapterChecks.ps1
.\Tests\Static\Invoke-CleanupRecoveryChecks.ps1
.\Tests\Static\Invoke-PodmanBootstrapChecks.ps1
```

Die statischen Prüfungen benötigen keine laufende SQL-Server-Instanz. Sie kontrollieren unter anderem:

- JSON-Syntax der Kataloge, Schemas und Beispiele;
- Existenz referenzierter Schema-Dateien;
- Import des Modulmanifests;
- Übereinstimmung von `FunctionsToExport` und tatsächlich verfügbaren Funktionen;
- schema- und fachgerechte Manifest-Erstellung ohne Provisionierung;
- Ablehnung unbekannter Felder, doppelter IDs, Providerkonflikte und inkompatibler Datenbankoptionen;
- Existenz der in Provider-Metadaten angegebenen Module;
- zentrale Dokumentationslinks;
- SQL- und Datenbank-Readiness-Verträge;
- Ausschluss bekannter veralteter Beispiele und Statusangaben.
- ProviderSubRuns, Mixed-Provider-Beispiel und Cleanup-Zuordnung.
- Trust Store, inhaltsadressierten Artifact Cache, Quarantäne und sanitisiertes Run Lock mit ausschliesslich synthetischen Testbytes.
- Sample-Backup-Handler-Vertrag: Katalogfilterung, Auflösung, Idempotenz- und Trust-Metadaten sowie den nicht interaktiven `TRUST_REQUIRED`-Pfad ohne Netzwerk oder Container.
- Project-Adapter-Vertrag: Schema, Versions- und Capability-Gates sowie die Pfadgrenzen des Adapter-Roots anhand manipulierter Kopien.
- Cleanup-/Recovery-Vertrag: sichtbarer Providerfehler, persistierter
  `RECOVERY_REQUIRED`-State, Fehlerhistorie und erfolgreicher Wiederholungsversuch.
- Podman-Bootstrap: bereits erreichbare Runtime, eindeutige Machine-Auswahl,
  Startfehler, Timeout und hostweit serialisierter Parallelstart.

Der interaktive Menüpfad darf das bereits laufende Modul nicht innerhalb von `Invoke-SqlServerLab` erneut mit `Import-Module -Force` laden. Eine Selbst-Neuladung entfernt die gerade verwendeten Hilfsfunktionen aus dem Funktionskontext.

## Einzelprovider-Smoke-Test

Der bestehende Test prüft einen explizit gewählten Provider vollständig:

```powershell
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-SmokeTest.ps1 -Provider podman
```

`-Provider auto` wählt weiterhin genau einen erreichbaren Provider, bevorzugt Docker vor Podman. Ein erfolgreicher Docker-Lauf ist kein Nachweis für Podman und umgekehrt.

## Gemischter Container-Provider-Smoke-Test

Der folgende Test prüft Docker und Podman innerhalb eines gemeinsamen Runs:

```powershell
.\Tests\Integration\Invoke-MixedProviderSmokeTest.ps1
```

Er benötigt einen Runner, auf dem beide Runtimes erreichbar sind. Die beiden
Instanzen gehören zu einem einzelnen Lab und werden im Lifecycle nicht parallel
als unabhängige Jobs provisioniert.

Eine vorhandene, gestoppte Podman-Machine wird vor Podman- und Mixed-Smokes
durch `Tests/Integration/Initialize-PodmanRuntime.ps1` automatisch gestartet.
Podman muss installiert und mindestens eine Machine bereits angelegt sein.

## Backup-/Restore-Smoke-Test

Der echte Restore-Test verwendet ausschliesslich eine zur Laufzeit erzeugte
synthetische Datenbank. Er erzeugt ein temporaeres `.bak`, prueft dessen
SHA-256 und stellt es ueber die gespeicherte Run-/Providerbindung wieder her:

```powershell
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
.\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider podman
```

Die Remote-Workflows fuehren den Test nach der jeweiligen vollstaendigen
Docker- beziehungsweise Podman-Matrix unter demselben hostweiten Mutex aus.

## Provider- und Versionsmatrix

Der bevorzugte übergreifende Test ist:

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1
```

Ohne weitere Parameter werden alle implementierten und lokal erreichbaren Provider erkannt. Pro Provider wird ein vollständiger Lifecycle mit der Referenzversion ausgeführt:

```text
Provisionierung
→ Datenbank
→ SQL-Skript
→ Restart
→ Persistenzprüfung
→ Stop
→ Start
→ Cleanup
```

Nicht erreichbare Provider werden als `SKIP` ausgewiesen. Ein erreichbarer, aber fehlerhafter Provider führt zu `FAIL` und Exitcode `1`.

### Vollständige Versionsmatrix

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider all `
    -FullMatrix
```

Dabei werden die SQL-Server-Versionen 2019, 2022 und 2025 pro erreichbarem Provider provisioniert, gegen die tatsächliche Major-Version geprüft und wieder entfernt. Die Referenzversion erhält zusätzlich den vollständigen Lifecycle-Test.

### Parallelitätsprüfung

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider all `
    -IncludeParallel
```

Der Paralleltest prüft gleichzeitig laufende Labs je verfügbarem Provider. Aktuell werden bis zu vier Szenarien verwendet:

- Docker / SQL Server 2022;
- Docker / SQL Server 2025;
- Podman / SQL Server 2022;
- Podman / SQL Server 2025.

Geprüft werden:

- eindeutige RunIds und ScopeIds;
- eindeutige Hostports;
- voneinander getrennte Run-States;
- isolierter Cleanup eines Runs;
- Fortbestand der übrigen Runs;
- vollständiger abschließender Cleanup.

### Vollständige lokale Abnahme

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider all `
    -FullMatrix `
    -IncludeParallel
```

## Remote Runner

Die Runtime-Tests verwenden ausschließlich dafür gekennzeichnete Self-hosted Runner:

| Workflow | Erforderliche Labels |
|---|---|
| Docker Runtime Smoke | `self-hosted`, `SQL_Lab`, `Docker` |
| Podman Runtime Smoke | `self-hosted`, `SQL_Lab`, `Podman` |
| Mixed Provider Runtime Smoke | `self-hosted`, `SQL_Lab`, `Docker`, `Podman` |

Die Workflows werden bewusst nicht auf einem generischen `self-hosted`-Runner ausgeführt. Der mutierende Teil jedes Docker-, Podman- und Mixed-Provider-Smoke-Tests hält einen gemeinsamen hostweiten Mutex. Dadurch können auf demselben Runner keine zwei Runtime-Lifecycle-Tests gleichzeitig Ressourcen erzeugen oder entfernen, ohne dass GitHub wartende Workflow-Läufe verwerfen muss. Die Parallelität wird innerhalb des jeweiligen Smoke-Tests kontrolliert erzeugt.

Remote-Läufe befinden sich unter:

```text
.github/workflows/runtime-smoke-docker.yml
.github/workflows/runtime-smoke-podman.yml
.github/workflows/runtime-smoke-mixed-providers.yml
```

## Voraussetzungen

- PowerShell 7.2 oder neuer;
- laufendes Docker; Podman muss installiert sein, eine vorhandene gestoppte
  Podman-Machine wird automatisch gestartet;
- `sqlcmd`;
- genügend RAM, Storage und freie Ports im Bereich 14330 bis 14399;
- Zugriff auf die konfigurierten SQL-Server-Container-Images;
- für Podman unter Windows eine funktionierende Localhost-Weiterleitung, siehe `Documentation/HowTo/PODMAN_WINDOWS_NETWORKING.md`.

## Fehlerdiagnose

Fehlgeschlagene Labs für eine lokale Diagnose behalten:

```powershell
.\Tests\Integration\Invoke-SmokeMatrix.ps1 `
    -Provider docker `
    -KeepOnFailure
```

Danach:

```powershell
Get-SqlServerLab -Detailed

docker ps -a --filter 'label=sql-server-lab.run-id'
# oder
podman ps -a --filter 'label=sql-server-lab.run-id'
```

Die Remote-Workflows verwenden `KeepOnFailure` nicht. Sie versuchen den normalen testseitigen Cleanup und beenden den Job bei einem Fehler mit Exitcode `1`.
